import Foundation
import FieldLogModels
import FieldLogFeatures
import FieldLogStorage
import MixerCore
import MixerUI
import MixerAndroid

public enum PublicHostError: Error { case bounds, surface, closed, profile, context, storage, action }
// A deliberately finite RFC3339 subset: Gregorian years 0001...9999,
// seconds 00...59, 1...3 fractional digits, and Z or an explicit ±HH:MM.
// Civil-day arithmetic rejects invalid dates without calendar normalization.
private enum EntryDateText {
    static func format(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }
    static func parse(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard (20...29).contains(b.count) else { return nil }
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= b.count else { return nil }
            var value = 0
            for byte in b[start..<(start + count)] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
              let year = number(0, 4), (1...9999).contains(year),
              let month = number(5, 2), (1...12).contains(month),
              let day = number(8, 2), (1...31).contains(day),
              let hour = number(11, 2), hour < 24,
              let minute = number(14, 2), minute < 60,
              let second = number(17, 2), second < 60 else { return nil }
        var index = 19, fraction = 0.0
        if b[index] == 46 {
            index += 1
            let start = index
            while index < b.count, (48...57).contains(b[index]) { index += 1 }
            let digits = index - start
            guard (1...3).contains(digits), let value = number(start, digits) else { return nil }
            fraction = Double(value) / (digits == 1 ? 10 : digits == 2 ? 100 : 1000)
        }
        guard index < b.count else { return nil }
        let offset: Int
        if b[index] == 90, index + 1 == b.count { offset = 0 }
        else {
            guard index + 6 == b.count, b[index] == 43 || b[index] == 45,
                  b[index + 3] == 58, let hours = number(index + 1, 2), hours < 24,
                  let minutes = number(index + 4, 2), minutes < 60 else { return nil }
            // RFC3339 -00:00 denotes an unknown local offset; this UI requires a known one.
            guard !(b[index] == 45 && hours == 0 && minutes == 0) else { return nil }
            offset = (hours * 3600 + minutes * 60) * (b[index] == 45 ? -1 : 1)
        }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= lengths[month - 1] else { return nil }
        let previousYear = year - 1
        let daysBeforeYear = 365 * previousYear + previousYear / 4 - previousYear / 100 + previousYear / 400
        let days = daysBeforeYear + lengths.prefix(month - 1).reduce(0, +) + day - 1 - 719162
        let seconds = Double(days) * 86400 + Double(hour * 3600 + minute * 60 + second - offset) + fraction
        let date = Date(timeIntervalSince1970: seconds)
        return date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }
    static let help = "Use YYYY-MM-DDTHH:mm:ss[.SSS]Z or ±HH:MM (known offset). Gregorian years 0001–9999; 1–3 fractional digits; no leap seconds. Example: 2024-02-29T14:30:00+05:30. Native calendar picker is not available here."
    static let error = "Enter a complete valid date and time with Z or a known ±HH:MM offset, and at most 3 fractional digits. Save is blocked; your input is retained."
}

// An app-owned native service contract, separate from Mixer UI event payloads.
public struct PhotoSelectionRequest: Sendable, Equatable {
    public let id: UUID
    public let draftID: UUID
    fileprivate let generation: UUID
}
public enum PhotoSelectionFailure: Sendable { case denied, invalid, tooLarge, unavailable }
public enum PhotoSelectionResult: Sendable { case cancelled, failed(PhotoSelectionFailure), jpeg(Data) }

// App-owned attachment service. No report data is carried by Mixer UI actions.
public struct ReportShareRequest: Sendable {
    public let id: UUID
    public let projectID: UUID
    public let revision: UInt64
    public let fileURL: URL
    public let byteCount: Int
    public let descriptor: Int32
    fileprivate let generation: UUID
}
public enum ReportShareResult: Sendable { case opened, closed, unavailable }

@MainActor private final class SaveAdmission {
    var accepted = false
    var preflight: (@Sendable (Workspace) throws -> Void)?
}

private enum WorkspaceEdit: Sendable {
    case complete(UUID), order(UUID, [UUID])
    func apply(_ workspace: inout Workspace) throws {
        switch self {
        case .complete(let id): try workspace.toggleTask(id)
        case .order(let project, let ids): try workspace.reorderTasks(projectID: project, ids: ids)
        }
    }
}

@MainActor public final class ProjectPresentation: AndroidUIBatchPresentation {
    public private(set) var snapshot: UIRenderSnapshot
    public private(set) var workspace: Workspace
    public var state: TaskEditorState { editor.state }
    private let repository: WorkspaceRepository
    private let projectID: UUID
    private var editor: TaskEditor
    private var editorObservation: UUID?
    private var reconciler: UIReconciler
    private var publishedState = TaskEditorState()
    private var renderingFailure: (any Error)?
    private var closed = false
    private var showingQueue = false
    private var showingEntries = false
    private var entryEditor: EntryEditor?
    private var entryObservation: UUID?
    private var entryDateInput: (draftID: UUID, text: String)?
    private var publishedEntryState: EntryEditorState?
    public var entryState: EntryEditorState? { entryEditor?.state }
    private var photoGeneration = UUID()
    private var photoRequest: PhotoSelectionRequest?
    private var photoDelivered = false
    private var photoReserved = false
    private var photoApplying = false
    private var photoMessage: String?
    private var photoCompletion: Task<Bool, Never>?
    var photoDrainBarrier: (@MainActor () async -> Void)?
    public var photoSelectionPending: Bool { photoRequest != nil }
    // 32MiB admitted snapshot text + <=10k tasks*16 and <=10k entries*256
    // bytes of report framing +4KiB header <36MiB. Never truncate a report.
    public nonisolated static let maximumReportBytes = 36 * 1024 * 1024
    private var reportGeneration = UUID()
    private var reportRequest: ReportShareRequest?
    private var reportDelivered = false
    private var reportOpened = false
    private var reportPreparing = false
    private var reportReady = false
    private var reportMessage: String?
    private var reportTask: Task<Void, Never>?
    private var reportHandle: FileHandle?
    public var reportSharePending: Bool { reportPreparing || reportRequest != nil }
    private var entryPage = 0
    private var draftPage = 0
    // Twenty rows use at most 100 checklist children (standard SDK limit: 1000).
    private nonisolated static let pageSize = 20
    private var taskPage = 0
    private var queuePage = 0
    private var changingWorkspace = false
    private var change: Task<Void, Never>?
    private var changeFailure: String?
    private var changeFeedback: String?
    private var observers: [UUID: @MainActor (UIRenderSnapshot) -> Void] = [:]

    public convenience init(directory: URL) async throws {
        let repository = try WorkspaceRepository(directory: directory.appendingPathComponent("FieldLog", isDirectory: true))
        try await self.init(repository: repository)
    }
    // Internal composition point also permits deterministic storage scheduling tests.
    init(repository: WorkspaceRepository) async throws {
        do {
            var workspace = await repository.snapshot()
            if workspace.projects.isEmpty {
                workspace = try await repository.transact { next in
                    try next.createProject(title: "FieldLog", site: "Local workspace")
                }
            }
            guard let project = workspace.projects.first else { throw PublicHostError.storage }
            let editor = try TaskEditor(save: { _, _ in .failed("Unadmitted save") })
            var reconciler = UIReconciler(validator: UIValidator(supportedTextFieldAxes: AndroidUIProfile.measuredMultilineLongNotesV4.capabilities.textFieldAxes, textValuePolicy: AndroidUIProfile.measuredMultilineLongNotesV4.textValuePolicy))
            try reconciler.apply(Self.document(editor.state, workspace: workspace, project: project.id, queue: false, taskPage: 0, queuePage: 0, busy: false, feedback: nil, failure: nil, revision: 1))
            self.repository = repository; self.workspace = workspace; self.projectID = project.id
            self.editor = editor; self.reconciler = reconciler; self.snapshot = try reconciler.currentSnapshot()
            _ = try Self.appPacket(snapshot)
            if let id = workspace.restoration.openDraftID,
               let draft = workspace.drafts.first(where: { $0.id == id && $0.projectID == project.id }) {
                try selectEntry(draft)
            }
        } catch { await repository.close(); throw error }
    }
    // V4's SDK value policy covers vertical fields. The app opts only its note
    // into that allowance, including transaction projections that have no event.
    private nonisolated static func appPacket(_ snapshot: UIRenderSnapshot) throws -> Data {
        var pending = [snapshot.document.root]
        while let node = pending.popLast() {
            if node.kind == .textField, node.id != "entry.note", let value = node.properties["value"]?.string {
                guard UITextValuePolicy.standard.accepts(value, for: node) else {
                    throw UIValidationError.limitExceeded("stringBytes")
                }
                guard !value.utf8.contains(0) else {
                    throw UIValidationError.invalidProperty(node: node.id, key: "value")
                }
            }
            pending.append(contentsOf: node.children)
        }
        return try snapshot.encodeNativePacketV1(supportedTextFieldAxes: AndroidUIProfile.measuredMultilineLongNotesV4.capabilities.textFieldAxes,
            textValuePolicy: AndroidUIProfile.measuredMultilineLongNotesV4.textValuePolicy)
    }
    public func observe(_ receive: @escaping @MainActor (UIRenderSnapshot) -> Void) -> @MainActor () -> Void {
        let id = UUID(); observers[id] = receive
        return { [weak self] in self?.observers.removeValue(forKey: id) }
    }
    public func send(_ event: UIEventEnvelope) throws { try sendBatch([event], from: snapshot) }

    public func sendBatch(_ events: [UIEventEnvelope], from captured: UIRenderSnapshot) throws {
        guard !closed, !state.saving, entryState?.saving != true, !changingWorkspace, !photoApplying, !reportPreparing else { throw PublicHostError.closed }
        guard !events.isEmpty, events.count <= AndroidUIHost.maximumBatchEvents,
              try JSONEncoder().encode(events).count <= AndroidUIProfile.measuredMultilineLongNotesV4.maximumEventBytes else { throw PublicHostError.bounds }
        guard captured.document == snapshot.document else { throw AndroidUIHostError.sourceChanged }
        // Route the complete original batch before any state change or repository effect.
        let actions = try events.map { try captured.route($0) }
        // Public V4 grants long values to vertical fields. FieldLog selects that
        // permission only for its note; every other field keeps the standard bound.
        for action in actions {
            if case let .string(value) = action.value, action.nodeID != "entry.note" {
                guard value.utf8.count <= UIValidationLimits.standard.maximumStringBytes,
                      !value.utf8.contains(0) else { throw PublicHostError.bounds }
            }
        }
        if actions.count == 1, let action = actions.first, action.event == .activate, action.value == .null {
            if action.nodeID == "workspace.report", action.actionID == "workspace.report" {
                guard !showingEntries, !showingQueue else { throw PublicHostError.action }
                try beginReport(); return
            }
            if action.nodeID == "workspace.entries", action.actionID == "workspace.entries" {
                if entryEditor == nil { try selectEntry(nil) } else { try navigateEntries(true) }; return
            }
            if action.nodeID == "workspace.tasks", action.actionID == "workspace.tasks" { try navigateEntries(false); return }
            if showingEntries && !showingQueue {
                if action.nodeID == "entry.photo.cancel", action.actionID == "entry.photo.cancel" { try cancelPhoto(); return }
                if action.nodeID == "entry.new", action.actionID == "entry.new" { try selectEntry(nil); return }
                for draft in workspace.drafts where draft.projectID == projectID {
                    let key = "draft." + draft.id.uuidString.lowercased()
                    if action.nodeID == key, action.actionID == key { try selectEntry(draft); return }
                }
                if action.actionID == action.nodeID {
                    switch action.nodeID {
                    case "entries.previous": try turnEntryPage(drafts: false, delta: -1); return
                    case "entries.next": try turnEntryPage(drafts: false, delta: 1); return
                    case "drafts.previous": try turnEntryPage(drafts: true, delta: -1); return
                    case "drafts.next": try turnEntryPage(drafts: true, delta: 1); return
                    default: break
                    }
                }
            }
            if action.nodeID == "workspace.queue", action.actionID == "workspace.queue" { try navigate(queue: true); return }
            if action.nodeID == "workspace.back", action.actionID == "workspace.back" { try navigate(queue: false); return }
            if action.nodeID == "task.new", action.actionID == "task.new", state.saved { try replaceEditor(newTask: true, actions: []); return }
            if action.actionID == action.nodeID {
                switch action.nodeID {
                case "tasks.previous": try turnPage(queue: false, delta: -1); return
                case "tasks.next": try turnPage(queue: false, delta: 1); return
                case "queue.previous": try turnPage(queue: true, delta: -1); return
                case "queue.next": try turnPage(queue: true, delta: 1); return
                default: break
                }
            }
            for (index, task) in workspace.tasks(for: projectID).enumerated() {
                let key = "task." + task.id.uuidString.lowercased()
                guard action.actionID == action.nodeID else { continue }
                if action.nodeID == key + ".complete" { try begin(.complete(task.id), focus: task.id); return }
                if action.nodeID == key + ".up" || action.nodeID == key + ".down" {
                    var ids = workspace.tasks(for: projectID).map(\.id)
                    let destination = index + (action.nodeID == key + ".up" ? -1 : 1)
                    guard ids.indices.contains(destination) else { throw PublicHostError.action }
                    ids.swapAt(index, destination); try begin(.order(projectID, ids), focus: task.id); return
                }
            }
        }
        if showingEntries && !showingQueue { try editEntry(actions); return }
        guard !state.saved, !showingQueue, !showingEntries else { throw PublicHostError.action }
        for (index, action) in actions.enumerated() {
            switch (action.nodeID, action.actionID, action.event, action.value) {
            case ("task.title", "task.title.change", .textChange, .string),
                 ("task.responsible", "task.responsible.change", .textChange, .string): break
            case ("task.save", "task.save", .activate, .null):
                guard index == actions.count - 1 else { throw PublicHostError.action }
            default: throw PublicHostError.action
            }
        }
        try replaceEditor(newTask: false, actions: actions)
    }


    private func beginReport() throws {
        guard reportRequest == nil, !reportPreparing else { throw PublicHostError.action }
        let frozen = workspace
        let id = UUID(), generation = reportGeneration, project = projectID
        reportPreparing = true; reportReady = false
        reportDelivered = false; reportOpened = false; reportMessage = "Preparing saved local report…"
        do { try photoRefresh() } catch { reportPreparing = false; throw error }
        reportTask = Task { @MainActor [self] in
            defer { reportTask = nil; reportPreparing = false }
            do {
                let bytes = try await Task.detached {
                    let data = Data(try frozen.report(projectID: project).utf8)
                    guard !data.isEmpty, data.count <= Self.maximumReportBytes else { throw PublicHostError.bounds }
                    return data
                }.value
                guard !closed, generation == reportGeneration,
                    await repository.snapshot() == frozen else { throw PublicHostError.storage }
                let url = try await repository.exportReport(projectID: project)
                let handle = try await Task.detached {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard (attributes[.size] as? NSNumber)?.intValue == bytes.count else { throw PublicHostError.bounds }
                    let handle = try FileHandle(forReadingFrom: url)
                    do {
                        guard try handle.read(upToCount: bytes.count + 1) == bytes else { throw PublicHostError.storage }
                        try handle.seek(toOffset: 0)
                        return handle
                    } catch { try? handle.close(); throw error }
                }.value
                guard !closed, generation == reportGeneration else { try? handle.close(); return }
                reportHandle = handle
                reportRequest = ReportShareRequest(id: id, projectID: project, revision: frozen.revision,
                    fileURL: url, byteCount: bytes.count, descriptor: handle.fileDescriptor, generation: generation)
                reportReady = true; reportMessage = "Report ready · Saved local records only. Photos are counted, not attached."
            } catch {
                guard !closed, generation == reportGeneration else { return }
                reportRequest = nil; reportReady = false
                reportMessage = "Report could not be prepared. Your saved records and unsaved input are retained."
            }
            reportPreparing = false
            if !closed { do { try photoRefresh() } catch { renderingFailure = error } }
        }
    }
    public func takeReportRequest() -> ReportShareRequest? {
        guard !closed, reportReady, !reportDelivered, let request = reportRequest else { return nil }
        reportDelivered = true
        return request
    }
    @discardableResult public func completeReport(requestID: UUID, result: ReportShareResult) -> Bool {
        guard !closed, reportDelivered, let request = reportRequest, request.id == requestID,
            request.generation == reportGeneration else { return false }
        switch result {
        case .opened:
            guard !reportOpened else { return false }
            reportOpened = true
            reportMessage = "Share sheet opened · Delivery is not confirmed. Saved local records only; photo files are not attached."
        case .closed:
            guard reportOpened else { return false }
            reportRequest = nil; reportReady = false; try? reportHandle?.close(); reportHandle = nil
            reportMessage = "Share sheet closed · Delivery is not confirmed."
        case .unavailable:
            reportRequest = nil; reportReady = false; try? reportHandle?.close(); reportHandle = nil
            reportMessage = "Sharing is unavailable. Your records and unsaved input are retained."
        }
        do { try photoRefresh(); return true } catch { renderingFailure = error; return false }
    }

    private func photoRefresh() throws {
        let (r, s) = try render(state, feedback: changeFeedback, failure: changeFailure)
        reconciler = r; snapshot = s; publish()
    }
    private func cancelPhoto() throws {
        guard photoRequest != nil, !photoApplying else { throw PublicHostError.action }
        photoRequest = nil; photoMessage = "Photo selection cancelled."
        try photoRefresh()
    }
    public func takePhotoRequest() -> PhotoSelectionRequest? {
        guard !closed, !photoDelivered, let request = photoRequest else { return nil }
        photoDelivered = true
        return request
    }
    @discardableResult public func completePhoto(requestID: UUID, result: PhotoSelectionResult) async -> Bool {
        guard !closed, !photoReserved, let request = photoRequest, request.id == requestID else { return false }
        photoReserved = true; photoApplying = true
        do { try photoRefresh() } catch {
            photoReserved = false; photoApplying = false; photoRequest = nil
            return false
        }
        let completion = Task { @MainActor [self] in
            defer {
                photoCompletion = nil; photoReserved = false; photoApplying = false
                if photoRequest == request { photoRequest = nil }
                if !closed { try? photoRefresh() }
            }
            await photoDrainBarrier?()
            await editor.waitForSave(); await entryEditor?.waitForSave(); await change?.value
            guard !closed, photoRequest == request, photoGeneration == request.generation,
                  let current = entryState, current.draft.id == request.draftID, current.committed == nil else { return false }
            do {
                switch result {
                case .cancelled: photoMessage = "Photo selection cancelled."
                case .failed(let reason):
                    switch reason {
                    case .denied: photoMessage = "Photo access was denied. Your entry is unchanged."
                    case .tooLarge: photoMessage = "Choose an image within the supported size. Your entry is unchanged."
                    case .invalid: photoMessage = "This image could not be decoded. Your entry is unchanged."
                    case .unavailable: photoMessage = "Photo selection is unavailable. Your entry is unchanged."
                    }
                case .jpeg(let jpeg):
                    let dateText = entryDateInput.flatMap { $0.draftID == current.draft.id ? $0.text : nil }
                    guard dateText == nil || EntryDateText.parse(dateText!) != nil else { throw PublicHostError.action }
                    try EntrySaveIntent(projectID: projectID, draft: current.draft, kind: .draft).validate()
                    photoMessage = "Saving photo on device…"; try photoRefresh()
                    let staged = current, task = state, project = projectID, r = reconciler
                    let tp = taskPage, qp = queuePage, ep = entryPage, dp = draftPage
                    let saved = try await repository.attachPhoto(jpeg: jpeg, to: current.draft, expectedRevision: workspace.revision) { next in
                        try Self.preflightEntry(next, state: staged, task: task, project: project,
                            taskPage: tp, queuePage: qp, entryPage: ep, draftPage: dp, reconciler: r, dateInput: dateText, photoPending: true,
                            photoMessage: "Saving photo on device…", photoBusy: true)
                    }
                    workspace = saved
                    // Close drains admitted IO, but never publishes a late UI.
                    if !closed {
                        guard let draft = saved.drafts.first(where: { $0.id == request.draftID }) else { throw PublicHostError.storage }
                        try replaceEntry(draft: draft, actions: [], preservingDateInput: true)
                    }
                    photoMessage = "Photo saved on device. Not uploaded."
                }
                return true
            } catch {
                photoMessage = "Photo was not accepted. Your entry is retained. Reopen after a storage error."
                return false
            }
        }
        photoCompletion = completion
        return await completion.value
    }

    private func navigateEntries(_ entries: Bool) throws {
        let (r, s) = try render(state, queue: false, entries: entries, feedback: changeFeedback, failure: changeFailure)
        showingQueue = false; showingEntries = entries; reconciler = r; snapshot = s; publish()
    }
    private func selectEntry(_ draft: EntryDraft?) throws {
        let old = (photoGeneration, photoRequest, photoMessage)
        photoGeneration = UUID(); photoRequest = nil; photoMessage = nil
        do { try replaceEntry(draft: draft, actions: []) }
        catch { (photoGeneration, photoRequest, photoMessage) = old; throw error }
    }
    private func editEntry(_ actions: [RoutedUIAction]) throws {
        guard let current = entryState, current.committed == nil else { throw PublicHostError.action }
        // All actions are still from the one original snapshot. Validate the entire
        // grammar before invoking a reducer or admitting its repository callback.
        for (index, action) in actions.enumerated() {
            switch (action.nodeID, action.actionID, action.event, action.value) {
            case ("entry.title", "entry.title.change", .textChange, .string),
                 ("entry.note", "entry.note.change", .textChange, .string),
                 ("entry.date.input", "entry.date.change", .textChange, .string): break
            case (let id, let actionID, .activate, .null) where EntryCategory.allCases.contains(where: { id == "entry.category." + $0.rawValue && actionID == id }): break
            case ("entry.photo.select", "entry.photo.select", .activate, .null):
                guard index == actions.count - 1, photoRequest == nil, current.draft.attachmentIDs.count < 8 else { throw PublicHostError.action }
            case ("entry.saveDraft", "entry.saveDraft", .activate, .null),
                 ("entry.commit", "entry.commit", .activate, .null):
                guard index == actions.count - 1 else { throw PublicHostError.action }
            default: throw PublicHostError.action
            }
        }
        try replaceEntry(draft: current.draft, actions: actions)
    }
    private func replaceEntry(draft: EntryDraft?, actions: [RoutedUIAction], preservingDateInput: Bool = false) throws {
        // Parse/bound all date input before constructing a reducer or any save effect.
        var dateText: String? = actions.isEmpty && !preservingDateInput ? nil : entryDateInput.flatMap { $0.draftID == draft?.id ? $0.text : nil }
        var parsedDates: [Int: Date] = [:]
        for (index, action) in actions.enumerated() {
            if action.nodeID == "entry.date.input", case .string(let value) = action.value {
                guard value.utf8.count <= UIValidationLimits.standard.maximumStringBytes,
                      !value.utf8.contains(0) else { throw PublicHostError.bounds }
                if value != (dateText ?? draft.map { EntryDateText.format($0.occurredAt) }) {
                    parsedDates[index] = EntryDateText.parse(value)
                }
                dateText = value
            }
            if action.nodeID == "entry.saveDraft" || action.nodeID == "entry.commit" || action.nodeID == "entry.photo.select" {
                guard dateText == nil || EntryDateText.parse(dateText!) != nil else { throw PublicHostError.action }
            }
        }
        let admission = SaveAdmission(), repository = self.repository
        let expected = workspace.revision, project = projectID
        let candidate = try EntryEditor(projectID: project, draft: draft) { [weak self] intent in
            guard await admission.accepted, let preflight = await admission.preflight else { return .failed("Unadmitted save") }
            do {
                let saved = try await repository.transact(expectedRevision: expected) { next in
                    try intent.apply(to: &next)
                    try preflight(next)
                }
                await self?.entryWorkspace(saved)
                return try intent.result(in: saved)
            } catch { return .failed(error.localizedDescription) }
        }
        let priorPhoto = (photoRequest, photoDelivered, photoReserved, photoMessage)
        do {
            for (index, action) in actions.enumerated() {
                switch (action.nodeID, action.event, action.value) {
                case ("entry.date.input", .textChange, .string):
                    if let date = parsedDates[index] { try candidate.changeOccurredAt(date) }
                case ("entry.title", .textChange, .string(let text)): try candidate.changeTitle(text)
                case ("entry.note", .textChange, .string(let text)): try candidate.changeNote(text)
                case ("entry.photo.select", .activate, .null):
                    try EntrySaveIntent(projectID: project, draft: candidate.state.draft, kind: .draft).validate()
                    photoRequest = PhotoSelectionRequest(id: UUID(), draftID: candidate.state.draft.id, generation: photoGeneration)
                    photoDelivered = false; photoReserved = false
                    photoMessage = "Choosing photo… Cancel to keep editing without a photo."
                case ("entry.saveDraft", .activate, .null): try candidate.saveDraft()
                case ("entry.commit", .activate, .null): try candidate.commitDraft()
                case (let id, .activate, .null):
                    guard let category = EntryCategory.allCases.first(where: { id == "entry.category." + $0.rawValue }) else { throw PublicHostError.action }
                    try candidate.changeCategory(category)
                default: throw PublicHostError.action
                }
            }
            let (r, s) = try render(state, queue: false, entries: true, entry: candidate.state, dateInput: dateText, feedback: nil, failure: nil)
            let staged = candidate.state, task = state, taskPage = self.taskPage, queuePage = self.queuePage, stagedDateText = dateText
            let entryPage = self.entryPage, draftPage = self.draftPage
            admission.preflight = { next in
                try Self.preflightEntry(next, state: staged, task: task, project: project,
                    taskPage: taskPage, queuePage: queuePage, entryPage: entryPage, draftPage: draftPage, reconciler: r, dateInput: stagedDateText)
            }
            if let entryObservation { entryEditor?.removeObserver(entryObservation) }
            try entryEditor?.close()
            entryEditor = candidate; entryDateInput = dateText.map { (candidate.state.draft.id, $0) }; showingQueue = false; showingEntries = true
            reconciler = r; snapshot = s
            publishedEntryState = candidate.state
            entryObservation = candidate.observe { [weak self] _ in self?.entryChanged() }
            admission.accepted = true; publish()
        } catch {
            (photoRequest, photoDelivered, photoReserved, photoMessage) = priorPhoto
            try? candidate.close(); throw error
        }
    }
    private func entryWorkspace(_ saved: Workspace) { workspace = saved }
    private func entryChanged() {
        guard !closed, entryState != publishedEntryState else { return }
        do {
            let (r, s) = try render(state, feedback: changeFeedback, failure: changeFailure)
            reconciler = r; snapshot = s; publishedEntryState = entryState; publish()
        } catch { renderingFailure = error; closed = true }
    }
    private func turnEntryPage(drafts: Bool, delta: Int) throws {
        let count = drafts ? workspace.drafts.filter { $0.projectID == projectID }.count : workspace.entries(for: projectID).count
        let current = Self.page(drafts ? draftPage : entryPage, count: count), destination = current + delta
        guard destination >= 0, destination <= Self.page(Int.max, count: count) else { throw PublicHostError.action }
        let (r, s) = try render(state, entryPage: drafts ? entryPage : destination, draftPage: drafts ? destination : draftPage, feedback: nil, failure: nil)
        if drafts { draftPage = destination } else { entryPage = destination }
        reconciler = r; snapshot = s; publish()
    }
    // The repository calls this with the real generated IDs and merged attachment
    // references, before revision increment, validation and atomic persistence.
    nonisolated static func preflightEntry(_ workspace: Workspace, state: EntryEditorState, task: TaskEditorState, project: UUID,
        taskPage: Int, queuePage: Int, entryPage: Int, draftPage: Int, reconciler: UIReconciler, dateInput: String? = nil,
        photoPending: Bool = false, photoMessage: String? = nil, photoBusy: Bool = false) throws {
        var committed = workspace
        guard committed.revision < UInt64.max else { throw PublicHostError.bounds }
        committed.revision += 1; try committed.validate()
        let revision = try reconciler.currentSnapshot().document.revision
        guard revision < UInt64.max else { throw PublicHostError.bounds }
        var completed = state; completed.saving = false; completed.failure = nil
        if let draft = committed.drafts.first(where: { $0.id == state.draft.id }) { completed.draft = draft; completed.savedDraft = draft }
        if let entry = committed.entries.first(where: { $0.id == state.draft.id }) { completed.committed = entry }
        for phase in [state, completed] {
            var projection = reconciler
            try projection.apply(document(task, workspace: committed, project: project, queue: false,
                taskPage: taskPage, queuePage: queuePage, busy: false, feedback: nil, failure: nil,
                revision: revision + 1, entries: true, entry: phase, entryPage: entryPage, draftPage: draftPage, dateInput: dateInput,
                photoPending: photoPending, photoMessage: photoMessage, photoBusy: photoBusy))
            _ = try appPacket(projection.currentSnapshot())
        }
    }
    private nonisolated static func entryDocument(_ state: EntryEditorState, workspace: Workspace, project: UUID, entryPage: Int, draftPage: Int, revision: UInt64, dateInput: String?, photoPending: Bool = false, photoMessage: String? = nil, photoBusy: Bool = false, reportPending: Bool = false, reportMessage: String? = nil) -> UIDocument {
        let inactive = state.saving || state.committed != nil || photoBusy
        let entries = workspace.entries(for: project), drafts = workspace.drafts.filter { $0.projectID == project }
        let ep = page(entryPage, count: entries.count), dp = page(draftPage, count: drafts.count)
        let dateValid = dateInput == nil || EntryDateText.parse(dateInput!) != nil
        let canCommit = (try? EntrySaveIntent(projectID: project, draft: state.draft, kind: .commit).validate()) != nil
        return MixerUI.Navigation("entry.screen", title: "Entries") {
            MixerUI.List("entry.form") {
                MixerUI.Section("entry.navigation") {
                    MixerUI.Button("workspace.tasks", "Tasks", action: "workspace.tasks").accessibilityIdentifier("workspace-tasks").disabled(state.saving)
                    MixerUI.Button("workspace.queue", "On device · \(workspace.outbox.count) pending changes · Not sent", action: "workspace.queue").accessibilityIdentifier("workspace-on-device").disabled(state.saving)
                    MixerUI.Button("entry.new", "New entry", action: "entry.new").accessibilityIdentifier("entry-new").disabled(state.saving)
                }
                MixerUI.Section("entry.fields", title: "Entry") {
                    MixerUI.TextField("entry.title", "Title", value: state.draft.title, action: "entry.title.change", axis: .vertical).accessibilityIdentifier("entry-title").disabled(inactive)
                    MixerUI.TextField("entry.note", "Note", value: state.draft.note, action: "entry.note.change", axis: .vertical).accessibilityIdentifier("entry-note").disabled(inactive)
                    MixerUI.Text("entry.occurredAt", "Occurred at: " + state.draft.occurredAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)))
                    MixerUI.TextField("entry.date.input", "Date and time (include timezone)", value: dateInput ?? EntryDateText.format(state.draft.occurredAt), action: "entry.date.change").accessibilityIdentifier("entry-date").disabled(inactive)
                    MixerUI.Text("entry.date.help", EntryDateText.help)
                    if !dateValid { MixerUI.Text("entry.date.error", EntryDateText.error) }
                    MixerUI.Button("entry.photo.select", "Select photo", action: "entry.photo.select").accessibilityIdentifier("entry-photo-select").disabled(inactive || photoPending || state.draft.attachmentIDs.count >= 8)
                    if photoPending { MixerUI.Button("entry.photo.cancel", "Cancel photo selection", action: "entry.photo.cancel").accessibilityIdentifier("entry-photo-cancel").disabled(photoBusy) }
                    if let photoMessage { MixerUI.Text("entry.photo.status", photoMessage) }
                    MixerUI.Text("entry.attachments", "Attachments: \(state.draft.attachmentIDs.count) · References preserved")
                    MixerUI.Text("entry.category", "Category: " + state.draft.category.rawValue)
                    for category in EntryCategory.allCases {
                        MixerUI.Button("entry.category." + category.rawValue, category.rawValue.capitalized, action: "entry.category." + category.rawValue).accessibilityIdentifier("entry.category." + category.rawValue).disabled(inactive)
                    }
                    MixerUI.Button("entry.saveDraft", state.saving ? "Saving…" : "Save draft", action: "entry.saveDraft").accessibilityIdentifier("entry-save-draft").disabled(inactive || !dateValid)
                    MixerUI.Button("entry.commit", state.committed != nil ? "Saved on device" : "Commit entry", action: "entry.commit").accessibilityIdentifier("entry-commit").disabled(inactive || !canCommit || !dateValid)
                    if state.savedDraft != nil { MixerUI.Text("entry.draftSaved", "Draft saved on device. Save again to keep later edits.") }
                    if let failure = state.failure { MixerUI.Text("entry.failure", String(decoding: failure.utf8.prefix(4000), as: UTF8.self)) }
                }
                MixerUI.Section("entry.drafts", title: "Saved drafts") {
                    MixerUI.Text("drafts.position", "Page \(dp + 1) of \(page(Int.max, count: drafts.count) + 1) · \(drafts.count) drafts")
                    MixerUI.Button("drafts.previous", "Previous drafts", action: "drafts.previous").disabled(state.saving || dp == 0)
                    MixerUI.Button("drafts.next", "Next drafts", action: "drafts.next").disabled(state.saving || (dp + 1) * pageSize >= drafts.count)
                    for draft in drafts.dropFirst(dp * pageSize).prefix(pageSize) {
                        MixerUI.Button("draft." + draft.id.uuidString.lowercased(), draft.title.isEmpty ? "Untitled draft" : draft.title, action: "draft." + draft.id.uuidString.lowercased()).accessibilityIdentifier("draft." + draft.id.uuidString.lowercased()).disabled(state.saving)
                    }
                }
                MixerUI.Section("entry.saved", title: "Saved entries") {
                    MixerUI.Text("entries.position", "Page \(ep + 1) of \(page(Int.max, count: entries.count) + 1) · \(entries.count) entries")
                    MixerUI.Button("entries.previous", "Previous entries", action: "entries.previous").disabled(state.saving || ep == 0)
                    MixerUI.Button("entries.next", "Next entries", action: "entries.next").disabled(state.saving || (ep + 1) * pageSize >= entries.count)
                    for entry in entries.dropFirst(ep * pageSize).prefix(pageSize) {
                        MixerUI.Text("entry." + entry.id.uuidString.lowercased(), entry.title + " · " + entry.category.rawValue + " · " + entry.occurredAt.formatted(.iso8601))
                    }
                }
            }
        }.document(revision: revision)
    }
    private func replaceEditor(newTask: Bool, actions: [RoutedUIAction]) throws {
        let admission = SaveAdmission()
        let repository = self.repository, projectID = self.projectID, revision = workspace.revision
        let candidate = try TaskEditor(save: { [weak self] title, responsible in
            guard await admission.accepted, let preflight = await admission.preflight else { return .failed("Unadmitted save") }
            do {
                let saved = try await repository.transact(expectedRevision: revision) { next in
                    try next.saveTask(projectID: projectID, title: title, responsible: responsible)
                    try preflight(next)
                }
                try await self?.savedWorkspace(saved)
                return .saved
            } catch { return .failed(error.localizedDescription) }
        })
        do {
            if !newTask { try candidate.changeTitle(state.title); try candidate.changeResponsible(state.responsible) }
            for action in actions {
                switch (action.nodeID, action.event, action.value) {
                case ("task.title", .textChange, .string(let text)): try candidate.changeTitle(text)
                case ("task.responsible", .textChange, .string(let text)): try candidate.changeResponsible(text)
                case ("task.save", .activate, .null): try candidate.submit()
                default: throw PublicHostError.action
                }
            }
            let (nextReconciler, next) = try render(candidate.state, feedback: nil, failure: nil)
            let stagedState = candidate.state, queuePage = self.queuePage
            admission.preflight = { workspace in
                guard let added = workspace.tasks.last else { throw PublicHostError.action }
                try Self.preflight(workspace, state: stagedState, project: projectID,
                    taskPage: Self.focusPage(added.id, workspace: workspace, project: projectID),
                    queuePage: queuePage, reconciler: nextReconciler)
            }
            if let editorObservation { editor.removeObserver(editorObservation) }
            try editor.close()
            editor = candidate; reconciler = nextReconciler; snapshot = next; publishedState = candidate.state
            changeFailure = nil; changeFeedback = nil
            editorObservation = candidate.observe { [weak self] state in self?.changed(state) }
            admission.accepted = true
            publish()
        } catch { try? candidate.close(); throw error }
    }
    private func navigate(queue: Bool) throws {
        let (nextReconciler, next) = try render(state, queue: queue, entries: queue ? showingEntries : false, feedback: changeFeedback, failure: changeFailure)
        showingQueue = queue; if !queue { showingEntries = false }; reconciler = nextReconciler; snapshot = next; publish()
    }
    private func turnPage(queue: Bool, delta: Int) throws {
        guard queue == showingQueue else { throw PublicHostError.action }
        let count = queue ? workspace.outbox.count : workspace.tasks(for: projectID).count
        let current = Self.page(queue ? queuePage : taskPage, count: count), destination = current + delta
        guard destination >= 0, destination <= Self.page(Int.max, count: count) else { throw PublicHostError.action }
        let (nextReconciler, next) = try render(state, taskPage: queue ? taskPage : destination,
            queuePage: queue ? destination : queuePage, feedback: changeFeedback, failure: changeFailure)
        if queue { queuePage = destination } else { taskPage = destination }
        reconciler = nextReconciler; snapshot = next; publish()
    }
    private func begin(_ edit: WorkspaceEdit, focus: UUID) throws {
        let (nextReconciler, next) = try render(state, busy: true, feedback: nil, failure: nil)
        let revision = workspace.revision, stagedState = state, project = projectID, queuePage = self.queuePage
        changingWorkspace = true; changeFailure = nil; changeFeedback = nil
        reconciler = nextReconciler; snapshot = next; publish()
        change = Task { @MainActor [self] in
            do {
                workspace = try await repository.transact(expectedRevision: revision) { next in
                    try edit.apply(&next)
                    let destination = try Self.focusPage(focus, workspace: next, project: project)
                    try Self.preflight(next, state: stagedState, project: project, taskPage: destination,
                        queuePage: queuePage, reconciler: nextReconciler)
                }
                taskPage = try Self.focusPage(focus, workspace: workspace, project: project)
                changeFeedback = "Saved on device"
            } catch { changeFailure = error.localizedDescription }
            changingWorkspace = false
            guard !closed else { return }
            do {
                let (nextReconciler, next) = try render(state, feedback: changeFeedback, failure: changeFailure)
                reconciler = nextReconciler; snapshot = next; publish()
            } catch { renderingFailure = error; closed = true }
        }
    }
    private func savedWorkspace(_ saved: Workspace) throws {
        guard let added = saved.tasks.last else { throw PublicHostError.action }
        let destination = try Self.focusPage(added.id, workspace: saved, project: projectID)
        workspace = saved
        taskPage = destination
    }
    private func changed(_ state: TaskEditorState) {
        guard !closed, state != publishedState else { return }
        do {
            let (nextReconciler, next) = try render(state, feedback: changeFeedback, failure: changeFailure)
            reconciler = nextReconciler; snapshot = next; publishedState = state; publish()
        } catch { renderingFailure = error; closed = true }
    }
    private func render(_ state: TaskEditorState, workspace: Workspace? = nil, queue: Bool? = nil, entries: Bool? = nil, entry: EntryEditorState? = nil, dateInput: String? = nil, entryPage: Int? = nil, draftPage: Int? = nil, taskPage: Int? = nil, queuePage: Int? = nil, busy: Bool? = nil, feedback: String?, failure: String?) throws -> (UIReconciler, UIRenderSnapshot) {
        guard snapshot.document.revision < UInt64.max else { throw PublicHostError.bounds }
        var next = reconciler
        try next.apply(Self.document(state, workspace: workspace ?? self.workspace, project: projectID, queue: queue ?? showingQueue, taskPage: taskPage ?? self.taskPage, queuePage: queuePage ?? self.queuePage, busy: busy ?? changingWorkspace, feedback: feedback, failure: failure, revision: snapshot.document.revision + 1, entries: entries ?? showingEntries, entry: entry ?? entryState, entryPage: entryPage ?? self.entryPage, draftPage: draftPage ?? self.draftPage, dateInput: entry != nil ? dateInput : entryDateInput.flatMap { $0.draftID == entryState?.draft.id ? $0.text : nil }, photoPending: photoRequest != nil, photoMessage: photoMessage, photoBusy: photoApplying, reportPending: reportPreparing || reportRequest != nil, reportMessage: reportMessage))
        let result = try next.currentSnapshot()
        _ = try Self.appPacket(result)
        return (next, result)
    }
    private func publish() { for receive in Array(observers.values) { receive(snapshot) } }
    public func waitForSave() async throws {
        await editor.waitForSave(); await entryEditor?.waitForSave(); await change?.value; await reportTask?.value
        if let renderingFailure { throw renderingFailure }
    }
    public func close() async {
        closed = true; photoGeneration = UUID(); photoRequest = nil; reportGeneration = UUID(); reportRequest = nil; observers.removeAll()
        if let editorObservation { editor.removeObserver(editorObservation) }; editorObservation = nil
        await editor.waitForSave(); await entryEditor?.waitForSave(); await change?.value
        if let entryObservation { entryEditor?.removeObserver(entryObservation) }; entryObservation = nil
        await reportTask?.value
        try? reportHandle?.close(); reportHandle = nil
        _ = await photoCompletion?.value
        try? entryEditor?.close(); try? editor.close(); await repository.close()
    }
    // Called inside the repository mutation, after actual IDs/order exist and
    // before its atomic write. Pure value projections never touch UI ownership.
    nonisolated static func preflight(_ workspace: Workspace, state: TaskEditorState, project: UUID,
        taskPage: Int, queuePage: Int, reconciler: UIReconciler) throws {
        var committed = workspace
        guard committed.revision < UInt64.max else { throw PublicHostError.bounds }
        committed.revision += 1
        try committed.validate()
        let revision = try reconciler.currentSnapshot().document.revision
        guard revision < UInt64.max else { throw PublicHostError.bounds }
        var completed = state
        if state.saving { completed.saving = false; completed.saved = true; completed.failure = nil }
        for busy in [true, false] {
            var projection = reconciler
            try projection.apply(document(busy ? state : completed, workspace: committed, project: project,
                queue: false, taskPage: taskPage, queuePage: queuePage, busy: busy,
                feedback: !busy && !state.saving ? "Saved on device" : nil, failure: nil, revision: revision + 1))
            _ = try appPacket(projection.currentSnapshot())
        }
    }
    private nonisolated static func page(_ requested: Int, count: Int) -> Int {
        min(max(0, requested), max(0, (count - 1) / pageSize))
    }
    private nonisolated static func focusPage(_ id: UUID, workspace: Workspace, project: UUID) throws -> Int {
        guard let index = workspace.tasks(for: project).firstIndex(where: { $0.id == id }) else { throw PublicHostError.action }
        return index / pageSize
    }
    private nonisolated static func changeLabel(_ item: PendingChange, workspace: Workspace) -> String {
        let title = workspace.tasks.first { $0.id == item.recordID }?.title ?? "Task"
        switch item.kind {
        case .projectCreated: return "Project created"
        case .taskSaved: return "Task updated: " + title
        case .taskOrderChanged: return "Checklist reordered"
        case .entrySaved: return "Entry saved"
        }
    }
    private nonisolated static func document(_ state: TaskEditorState, workspace: Workspace, project: UUID, queue: Bool, taskPage: Int, queuePage: Int, busy: Bool, feedback: String?, failure: String?, revision: UInt64, entries: Bool = false, entry: EntryEditorState? = nil, entryPage: Int = 0, draftPage: Int = 0, dateInput: String? = nil, photoPending: Bool = false, photoMessage: String? = nil, photoBusy: Bool = false, reportPending: Bool = false, reportMessage: String? = nil) -> UIDocument {
        if entries && !queue, let entry { return entryDocument(entry, workspace: workspace, project: project, entryPage: entryPage, draftPage: draftPage, revision: revision, dateInput: dateInput, photoPending: photoPending, photoMessage: photoMessage, photoBusy: photoBusy) }
        let inactive = state.saving || busy
        let tasks = workspace.tasks(for: project)
        let taskPage = page(taskPage, count: tasks.count), queuePage = page(queuePage, count: workspace.outbox.count)
        let taskStart = taskPage * pageSize, queueStart = queuePage * pageSize
        return MixerUI.Navigation("task.screen", title: queue ? "On device" : "FieldLog") {
            MixerUI.List("task.form") {
                if queue {
                    MixerUI.Section("queue.summary", title: "On device") {
                        MixerUI.Text("queue.explanation", "Your records are saved locally. Cloud sync isn't connected. Nothing in this queue has been sent to a server.")
                        MixerUI.Button("workspace.back", "Tasks", action: "workspace.back").accessibilityIdentifier("workspace-tasks")
                        MixerUI.Button("workspace.entries", "Entries", action: "workspace.entries").accessibilityIdentifier("workspace-entries")
                    }
                    MixerUI.Section("queue.changes", title: "Pending changes (\(workspace.outbox.count))") {
                        MixerUI.Text("queue.position", "Page \(queuePage + 1) of \(page(Int.max, count: workspace.outbox.count) + 1) · Changes \(workspace.outbox.isEmpty ? 0 : queueStart + 1)–\(min(queueStart + pageSize, workspace.outbox.count)) of \(workspace.outbox.count) · Newest first")
                        MixerUI.Button("queue.previous", "Previous", action: "queue.previous").accessibilityIdentifier("queue.previous").disabled(inactive || queuePage == 0)
                        MixerUI.Button("queue.next", "Next", action: "queue.next").accessibilityIdentifier("queue.next").disabled(inactive || queueStart + pageSize >= workspace.outbox.count)
                        if workspace.outbox.isEmpty { MixerUI.Text("queue.empty", "Changes you make will appear here.") }
                        for item in workspace.outbox.reversed().dropFirst(queueStart).prefix(pageSize) {
                            MixerUI.Text("pending." + item.id.uuidString.lowercased(), changeLabel(item, workspace: workspace) + " — Saved on device · Not sent")
                        }
                    }
                } else {
                    MixerUI.Section("workspace.summary", title: "Local workspace") {
                        MixerUI.Button("workspace.report", "Share project report", action: "workspace.report").accessibilityIdentifier("workspace-report").disabled(inactive || reportPending)
                        MixerUI.Text("workspace.report.scope", "Saved local records only. Unsaved input and photo files are not included. Nothing is uploaded by FieldLog.")
                        if let reportMessage { MixerUI.Text("workspace.report.status", reportMessage) }
                        MixerUI.Button("workspace.entries", "Entries", action: "workspace.entries").accessibilityIdentifier("workspace-entries").disabled(inactive)
                        MixerUI.Text("workspace.progress", "\(tasks.filter(\.completed).count) of \(tasks.count) tasks completed")
                        MixerUI.Button("workspace.queue", "On device · \(workspace.outbox.count) pending changes · Not sent", action: "workspace.queue").accessibilityIdentifier("workspace-on-device").disabled(inactive)
                    }
                    MixerUI.Section("task.fields", title: "New task") {
                        MixerUI.TextField("task.title", "What needs to happen?", value: state.title, action: "task.title.change", axis: .vertical).accessibilityIdentifier("task-title").disabled(inactive || state.saved)
                        MixerUI.TextField("task.responsible", "Responsible person (optional)", value: state.responsible, action: "task.responsible.change").accessibilityIdentifier("task-responsible").disabled(inactive || state.saved)
                        MixerUI.Button("task.save", state.saved ? "Saved" : state.saving ? "Saving…" : "Save", action: "task.save").accessibilityIdentifier("task-save").disabled(!state.canSubmit || busy)
                        if state.saved {
                            MixerUI.Text("task.durable", "Saved on device")
                            MixerUI.Button("task.new", "New task", action: "task.new").accessibilityIdentifier("task-new").disabled(inactive)
                        }
                    }
                    if let failure = state.failure ?? failure {
                        MixerUI.Section("task.failure") { MixerUI.Text("task.failure.message", String(decoding: failure.utf8.prefix(4000), as: UTF8.self)) }
                    }
                    if busy || feedback != nil {
                        MixerUI.Section("workspace.feedback") { MixerUI.Text("workspace.feedback.message", busy ? "Saving…" : feedback ?? "") }
                    }
                    MixerUI.Section("workspace.tasks", title: "Checklist") {
                        MixerUI.Text("tasks.position", "Page \(taskPage + 1) of \(page(Int.max, count: tasks.count) + 1) · Tasks \(tasks.isEmpty ? 0 : taskStart + 1)–\(min(taskStart + pageSize, tasks.count)) of \(tasks.count)")
                        MixerUI.Button("tasks.previous", "Previous", action: "tasks.previous").accessibilityIdentifier("tasks.previous").disabled(inactive || taskPage == 0)
                        MixerUI.Button("tasks.next", "Next", action: "tasks.next").accessibilityIdentifier("tasks.next").disabled(inactive || taskStart + pageSize >= tasks.count)
                        if tasks.isEmpty { MixerUI.Text("tasks.empty", "Add a task to start your checklist.") }
                        for index in taskStart..<min(taskStart + pageSize, tasks.count) {
                            let task = tasks[index]
                            let key = "task." + task.id.uuidString.lowercased()
                            MixerUI.Text(key + ".title", "\(index + 1). " + task.title + (task.completed ? " · Completed" : " · Not completed"))
                            if !task.responsible.isEmpty { MixerUI.Text(key + ".responsible", task.responsible) }
                            MixerUI.Button(key + ".complete", (task.completed ? "Reopen: " : "Complete: ") + task.title, action: key + ".complete").accessibilityIdentifier(key + ".complete").disabled(inactive)
                            if tasks.count > 1 {
                                MixerUI.Button(key + ".up", "Move up: " + task.title, action: key + ".up").accessibilityIdentifier(key + ".up").disabled(inactive || index == 0)
                                MixerUI.Button(key + ".down", "Move down: " + task.title, action: key + ".down").accessibilityIdentifier(key + ".down").disabled(inactive || index == tasks.count - 1)
                            }
                        }
                    }
                }
            }
        }.document(revision: revision)
    }
}

@MainActor private final class Delivery {
    weak var host: AndroidUIHost?
    var failure: (any Error)?
    func schedule() {
        Task { @MainActor [weak self] in
            guard let self, let host, host.owner != nil else { return }
            do { try host.deliverLatest() } catch { failure = error }
        }
    }
}

@MainActor public final class PublicAndroidApplication {
    private let delivery = Delivery()
    public let presentation: ProjectPresentation
    public let host: AndroidUIHost
    public init(surface: any AndroidUINativeSurface, selectedProfile: String, directory: URL) async throws {
        guard selectedProfile == AndroidUIProfile.measuredMultilineLongNotesV4.rawValue,
              surface.profile == .measuredMultilineLongNotesV4 else { throw PublicHostError.profile }
        presentation = try await ProjectPresentation(directory: directory)
        host = try AndroidUIHost(surface: surface, profile: .measuredMultilineLongNotesV4,
            appearance: UIAppearanceDescriptorCodecV2.mixerDefaultV2(), scheduleDelivery: { [delivery] in delivery.schedule() })
        delivery.host = host
        do { try host.replace(with: presentation); try host.deliverLatest() }
        catch { host.close(); await presentation.close(); throw error }
    }
    public func send(owner: UUID, originalEnvelope: Data) throws {
        if let failure = delivery.failure { throw failure }
        guard originalEnvelope.count <= 1_048_576 else { throw PublicHostError.bounds }
        try JSONInputGuard.validate(originalEnvelope, limits: JSONInputLimits(maximumBytes: AndroidUIProfile.measuredMultilineLongNotesV4.maximumEventBytes, maximumDepth: 8, maximumValues: 64, maximumStringBytes: 100_000))
        try host.send(owner: owner, event: JSONDecoder().decode(UIEventEnvelope.self, from: originalEnvelope))
        try host.deliverLatest()
    }
    public func sendBatch(owner: UUID, originalEnvelopes: Data) throws {
        if let failure = delivery.failure { throw failure }
        guard !originalEnvelopes.isEmpty, originalEnvelopes.count <= AndroidUIProfile.measuredMultilineLongNotesV4.maximumEventBytes else { throw PublicHostError.bounds }
        try JSONInputGuard.validate(originalEnvelopes, limits: JSONInputLimits(maximumBytes: AndroidUIProfile.measuredMultilineLongNotesV4.maximumEventBytes, maximumDepth: 9, maximumValues: 2049, maximumStringBytes: 100_000))
        let events = try JSONDecoder().decode([UIEventEnvelope].self, from: originalEnvelopes)
        try host.sendBatch(owner: owner, events: events)
        try host.deliverLatest()
    }
    public func settle() async throws {
        try await presentation.waitForSave()
        if let failure = delivery.failure { throw failure }
        try host.deliverLatest()
    }
    public func close() async { host.close(); await presentation.close() }
}
