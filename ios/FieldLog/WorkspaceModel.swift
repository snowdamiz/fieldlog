import FieldLogModels
import FieldLogStorage
import SwiftUI

@MainActor final class WorkspaceModel: ObservableObject {
  @Published private(set) var workspace: Workspace?
  @Published private(set) var loading = true
  @Published private(set) var openError: String?
  @Published private(set) var saveError: String?
  @Published private(set) var pendingSaves = 0
  @Published private(set) var unsavedDrafts: [UUID: EntryDraft] = [:]
  @Published private(set) var isTestWorkspace = false
  private var repository: WorkspaceRepository?
  private var saveChain: Task<Bool, Never>?
  private var opened = false

  func open() async {
    guard !opened else { return }
    opened = true
    loading = true
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      var workspaceFolder = "FieldLog"
      let arguments = ProcessInfo.processInfo.arguments
      if let index = arguments.firstIndex(of: "--fieldlog-ui-workspace") {
        #if DEBUG
          guard arguments.indices.contains(index + 1),
            let identity = UUID(uuidString: arguments[index + 1])
          else {
            throw FieldLogError.validation(
              "A valid dedicated UI-test workspace identifier is required.")
          }
          workspaceFolder = "FieldLogUITest-" + identity.uuidString.lowercased()
          isTestWorkspace = true
        #else
          throw FieldLogError.validation(
            "UI-test workspaces require a Debug build. No workspace was opened.")
        #endif
      }
      let repository = try WorkspaceRepository(
        directory: support.appendingPathComponent(workspaceFolder, isDirectory: true))
      self.repository = repository
      workspace = await repository.snapshot()
      openError = nil
    } catch { openError = error.localizedDescription }
    loading = false
  }
  func retryOpen() async {
    opened = false
    await open()
  }

  @discardableResult private func enqueue(
    _ operation: @escaping @Sendable (inout Workspace) throws -> Void,
    completion: (@MainActor () -> Void)? = nil
  ) -> Task<Bool, Never> {
    let previous = saveChain
    pendingSaves += 1
    let next = Task { @MainActor in
      _ = await previous?.value
      defer { pendingSaves -= 1 }
      guard let repository else { return false }
      do {
        workspace = try await repository.transact(operation)
        completion?()
        if unsavedDrafts.isEmpty { saveError = nil }
        return true
      } catch {
        saveError = error.localizedDescription
        return false
      }
    }
    saveChain = next
    return next
  }
  func flush() async { _ = await saveChain?.value }
  func createProject(title: String, site: String) async -> UUID? {
    let id = UUID()
    let date = Date()
    let success = await enqueue {
      try $0.createProject(id: id, title: title, site: site, now: date)
    }.value
    return success ? id : nil
  }
  func addTask(projectID: UUID, title: String, responsible: String) async -> Bool {
    await enqueue { try $0.saveTask(projectID: projectID, title: title, responsible: responsible) }
      .value
  }
  func toggleTask(_ id: UUID) { enqueue { try $0.toggleTask(id) } }
  func reorder(projectID: UUID, ids: [UUID]) {
    enqueue { try $0.reorderTasks(projectID: projectID, ids: ids) }
  }
  func moveTask(_ id: UUID, offset: Int) {
    enqueue { state in
      guard let task = state.tasks.first(where: { $0.id == id }) else {
        throw FieldLogError.missingRecord
      }
      var ids = state.tasks(for: task.projectID).map(\.id)
      guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else {
        throw FieldLogError.validation("This task cannot move farther.")
      }
      ids.swapAt(index, index + offset)
      try state.reorderTasks(projectID: task.projectID, ids: ids)
    }
  }
  func restoreProject(_ id: UUID?) {
    guard workspace?.restoration.selectedProjectID != id else { return }
    enqueue { $0.restoration.selectedProjectID = id }
  }
  func newDraft(projectID: UUID) async -> EntryDraft? {
    let draft = EntryDraft(projectID: projectID)
    return await keepDraft(draft, open: true) ? draft : nil
  }
  func openDraft(_ id: UUID) { enqueue { $0.restoration.openDraftID = id } }
  func closeDraft() {
    guard workspace?.restoration.openDraftID != nil else { return }
    enqueue { $0.restoration.openDraftID = nil }
  }
  private func queueDraft(_ input: EntryDraft, open: Bool = false, close: Bool = false) -> Task<
    Bool, Never
  > {
    var draft = input
    draft.updatedAt = Date()
    let value = draft
    unsavedDrafts[draft.id] = draft
    return enqueue(
      { state in
        try state.saveDraft(value)
        if open { state.restoration.openDraftID = value.id }
        if close { state.restoration.openDraftID = nil }
      },
      completion: { [weak self] in
        guard let self else { return }
        if unsavedDrafts[value.id] == value { unsavedDrafts.removeValue(forKey: value.id) }
      })
  }
  @discardableResult func keepDraft(_ draft: EntryDraft, open: Bool = false, close: Bool = false)
    async -> Bool
  { await queueDraft(draft, open: open, close: close).value }
  func scheduleDraft(_ draft: EntryDraft) { _ = queueDraft(draft) }
  func commit(_ draft: EntryDraft) async -> Bool {
    let success = await enqueue { state in
      try state.saveDraft(draft)
      try state.commitDraft(draft.id)
    }.value
    if success { unsavedDrafts.removeValue(forKey: draft.id) }
    return success
  }
  func addPhoto(_ jpeg: Data, draftID: UUID) async throws -> [UUID] {
    await flush()
    guard let repository else { throw FieldLogError.missingRecord }
    workspace = try await repository.addPhoto(jpeg: jpeg, to: draftID)
    return workspace?.drafts.first(where: { $0.id == draftID })?.attachmentIDs ?? []
  }
  func photoURL(_ id: UUID) async -> URL? { try? await repository?.photoURL(id) }
  func exportReport(projectID: UUID) async throws -> URL {
    await flush()
    guard let repository else { throw FieldLogError.missingRecord }
    return try await repository.exportReport(projectID: projectID)
  }
  var unsavedCount: Int { unsavedDrafts.count }
}
