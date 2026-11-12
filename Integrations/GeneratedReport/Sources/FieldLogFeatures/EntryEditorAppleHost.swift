#if canImport(SwiftUI)
import Foundation
import SwiftUI
import FieldLogModels
import MixerApple
import MixerUI

/// Native controls observe the shared feature directly. This adapter owns only
/// debounce/lifetime and native operation admission; EntryEditor owns domain state.
@MainActor public final class EntryEditorAppleHost: ObservableObject {
  @Published public private(set) var state: EntryEditorState
  public let titleHost: MixerUIHost
  public let noteHost: MixerUIHost
  private enum Operation {
    case draft(UUID, Task<Bool, Never>), done, commit, photo
  }
  @Published private var operation: Operation? {
    didSet { synchronizeFields() }
  }
  public var operationInProgress: Bool { operation != nil }
  @Published public private(set) var eventFailure: String?
  public var inputUnavailable: Bool { isClosed || operationInProgress || state.saving || state.committed != nil }
  public var hasUnsavedChanges: Bool { state.savedDraft != state.draft }
  public private(set) var isClosed = false
  private let feature: EntryEditor
  private var observation: UUID?
  private var autosave: Task<Void, Never>?

  public init(draft: EntryDraft,
    save: @escaping @Sendable (EntrySaveIntent) async -> EntrySaveResult) throws {
    feature = try EntryEditor(projectID: draft.projectID, draft: draft, save: save)
    state = feature.state
    titleHost = try MixerUIHost(document: Self.titleDocument(draft.title, revision: 1, disabled: false))
    noteHost = try MixerUIHost(document: Self.noteDocument(draft.note, revision: 1, disabled: false),
      validator: UIValidator(supportedTextFieldAxes: [.horizontal, .vertical], textValuePolicy: .longNoteV1))
    observation = feature.observe { [weak self] state in
      guard let self, !self.isClosed else { return }
      self.state = state
      self.synchronizeFields()
    }
  }

  public func receiveTitle(_ action: RoutedUIAction) {
    receive(action, from: titleHost, change: changeTitle)
  }

  public func receiveNote(_ action: RoutedUIAction) {
    receive(action, from: noteHost, change: changeNote)
  }

  public func fieldFailed(_ error: any Error) {
    guard !isClosed else { return }
    eventFailure = error.localizedDescription
  }

  private func receive(_ action: RoutedUIAction, from host: MixerUIHost, change: (String) -> Void) {
    guard !inputUnavailable else { return }
    do {
      guard let identity = host.snapshot.identity(for: action.nodeID) else { throw UIRoutingError.staleIdentity }
      let current = try host.route(UIEventEnvelope(revision: action.revision, identity: identity,
        event: action.event, value: action.value))
      guard current == action, case .textChange = current.event,
        case .string(let value) = current.value else { throw UIRoutingError.unboundEvent }
      change(value)
    } catch { fieldFailed(error) }
  }

  private static func titleDocument(_ value: String, revision: UInt64, disabled: Bool) -> MixerUI.UIDocument {
    MixerUI.TextField("entry-title", "Entry title", value: value, action: "entry.title.changed", axis: .vertical)
      .accessibilityIdentifier("entry-title").disabled(disabled).document(revision: revision)
  }

  private static func noteDocument(_ value: String, revision: UInt64, disabled: Bool) -> MixerUI.UIDocument {
    MixerUI.TextField("entry-note", "Field note", value: value, action: "entry.note.changed", axis: .vertical)
      .accessibilityLabel("Field note").accessibilityIdentifier("entry-note")
      .disabled(disabled).document(revision: revision)
  }

  private func synchronizeFields() {
    do {
      try titleHost.update(Self.titleDocument(state.draft.title,
        revision: titleHost.snapshot.document.revision + 1, disabled: inputUnavailable))
      try noteHost.update(Self.noteDocument(state.draft.note,
        revision: noteHost.snapshot.document.revision + 1, disabled: inputUnavailable))
    } catch { fieldFailed(error) }
  }

  public func changeTitle(_ value: String) { edit { try feature.changeTitle(value) } }
  public func changeNote(_ value: String) { edit { try feature.changeNote(value) } }
  public func changeCategory(_ value: EntryCategory) { edit { try feature.changeCategory(value) } }
  public func changeOccurredAt(_ value: Date) { edit { try feature.changeOccurredAt(value) } }

  private func edit(_ change: () throws -> Void) {
    guard !inputUnavailable else { return }
    do {
      try change(); eventFailure = nil
      autosave?.cancel()
      autosave = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let self, !Task.isCancelled, !self.isClosed else { return }
        self.autosave = nil
        _ = await self.saveDraft()
      }
    } catch { eventFailure = error.localizedDescription }
  }

  @discardableResult public func saveDraft() async -> Bool {
    autosave?.cancel(); autosave = nil
    guard !isClosed, !operationInProgress, state.committed == nil else { return false }
    let identity = UUID()
    let save = Task { @MainActor in await self.persistDraft() }
    operation = .draft(identity, save)
    let accepted = await save.value
    // A prepared photo may have taken ownership while this save was suspended.
    if case .draft(let active, _) = operation, active == identity { operation = nil }
    return accepted
  }

  /// Done closes restoration only after the exact shared save result is admitted.
  @discardableResult public func done(closeDraft: @MainActor () async -> Bool) async -> Bool {
    autosave?.cancel(); autosave = nil
    guard !isClosed, !operationInProgress, state.committed == nil else { return false }
    operation = .done
    defer { operation = nil }
    guard await persistDraft(), !isClosed else { return false }
    guard await closeDraft(), !isClosed else { return false }
    return true
  }

  @discardableResult public func commit() async -> Bool {
    autosave?.cancel(); autosave = nil
    guard !isClosed, !operationInProgress, state.committed == nil else { return false }
    operation = .commit
    defer { operation = nil }
    await feature.waitForSave()
    guard !isClosed else { return false }
    do { try feature.commitDraft() } catch { eventFailure = error.localizedDescription; return false }
    await feature.waitForSave()
    return !isClosed && state.committed != nil && state.failure == nil
  }

  /// Photo storage is native. A shared save first creates the durable draft;
  /// another shared result adopts references merged by Workspace.saveDraft.
  @discardableResult public func attachPhoto(
    _ attach: @MainActor (UUID) async throws -> Void
  ) async -> Bool {
    autosave?.cancel(); autosave = nil
    guard !isClosed, state.committed == nil, !Task.isCancelled else { return false }
    let priorSave: Task<Bool, Never>?
    switch operation {
    case .draft(_, let save): priorSave = save
    case nil:
      guard !state.saving else { return false }
      priorSave = nil
    default: return false
    }
    // Reserve the next operation before awaiting: no terminal action or second
    // photo can overtake an accepted import while the prior save drains.
    operation = .photo
    defer { operation = nil }
    if let priorSave {
      guard await priorSave.value, !isClosed, !Task.isCancelled else { return false }
    }
    guard await persistDraft(), !isClosed, !Task.isCancelled else { return false }
    let draftID = state.draft.id
    do { try await attach(draftID) } catch {
      if !isClosed { eventFailure = error.localizedDescription }
      return false
    }
    guard !isClosed, !Task.isCancelled else { return false }
    return await persistDraft()
  }

  private func persistDraft() async -> Bool {
    await feature.waitForSave()
    guard !isClosed, state.committed == nil else { return false }
    do { try feature.saveDraft(); eventFailure = nil }
    catch { eventFailure = error.localizedDescription; return false }
    await feature.waitForSave()
    return !isClosed && state.failure == nil && state.savedDraft == state.draft
  }

  /// Capture an in-flight batch before close to drain a cancellation-ignoring save.
  public func waitForSave() async { await feature.waitForSave() }

  public func close() throws {
    guard !isClosed else { return }
    isClosed = true
    autosave?.cancel(); autosave = nil
    if let observation { feature.removeObserver(observation) }
    observation = nil
    try feature.close()
    state = feature.state
    synchronizeFields()
  }
}
#endif
