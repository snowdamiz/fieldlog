import Foundation
import Testing

@testable import FieldLogModels
@testable import FieldLogStorage

private func folder() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "fieldlog-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}
private func mutate(_ workspace: inout Workspace, _ body: (inout Workspace) throws -> Void) throws {
  try body(&workspace)
  workspace.revision += 1
  try workspace.validate()
}

@Test func emptyWorkspaceNeverFabricatesActivity() throws {
  let state = Workspace()
  try state.validate()
  #expect(
    state.projects.isEmpty && state.tasks.isEmpty && state.entries.isEmpty && state.outbox.isEmpty)
  #expect(state.matchingProjects("").isEmpty)
}
@Test func projectsSearchAndTaskProgressUseRealDenominator() throws {
  var w = Workspace()
  var id = UUID()
  try mutate(&w) { id = try $0.createProject(title: "  East hall  ", site: "Brooklyn") }
  try mutate(&w) { try $0.saveTask(projectID: id, title: "Survey", responsible: "") }
  try mutate(&w) { try $0.saveTask(projectID: id, title: "Measure", responsible: "Rae") }
  #expect(w.progress(for: id) == 0)
  try mutate(&w) { try $0.toggleTask($0.tasks[0].id) }
  #expect(w.progress(for: id) == 0.5)
  #expect(w.matchingProjects("brook").map(\.id) == [id])
  #expect(w.projects[0].title == "East hall")
  #expect(w.matchingProjects("unrelated").isEmpty)
  #expect(Workspace().progress(for: UUID()) == 0)
}
@Test func validationAndReorderCannotLoseTasks() throws {
  var w = Workspace()
  var id = UUID()
  try mutate(&w) { id = try $0.createProject(title: "Site", site: "") }
  try mutate(&w) {
    try $0.saveTask(projectID: id, title: "One", responsible: "")
    try $0.saveTask(projectID: id, title: "Two", responsible: "")
  }
  let ids = w.tasks.map(\.id)
  try mutate(&w) { try $0.reorderTasks(projectID: id, ids: ids.reversed()) }
  #expect(w.tasks(for: id).map(\.id) == ids.reversed())
  #expect(throws: FieldLogError.self) { try w.reorderTasks(projectID: id, ids: [ids[0], ids[0]]) }
  #expect(throws: FieldLogError.self) {
    try w.saveTask(projectID: id, title: " \n", responsible: "")
  }
  #expect(throws: FieldLogError.self) {
    try w.createProject(title: String(repeating: "a", count: 161), site: "")
  }
  #expect(throws: FieldLogError.self) { try w.createProject(title: "\0", site: "") }
}
@Test func draftWhitespaceDatesAndIdentitySurviveCommit() throws {
  var w = Workspace()
  var project = UUID()
  try mutate(&w) { project = try $0.createProject(title: "Site", site: "") }
  let note = "  Keep spacing\n\nالعربية · 日本語\n"
  let draft = EntryDraft(
    projectID: project, title: "Check-in", note: note,
    occurredAt: Date(timeIntervalSince1970: 1792600000.125))
  try mutate(&w) {
    try $0.saveDraft(draft)
    $0.restoration.openDraftID = draft.id
  }
  let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
  #expect(restored == w)
  try mutate(&w) { try $0.commitDraft(draft.id) }
  #expect(w.entries[0].id == draft.id)
  #expect(w.entries[0].note == note)
  #expect(w.entries[0].occurredAt == draft.occurredAt)
  #expect(w.restoration.openDraftID == nil)
  #expect(w.drafts.isEmpty)
  let count = w.outbox.count
  #expect(throws: FieldLogError.self) { try w.commitDraft(draft.id) }
  #expect(w.entries.count == 1 && w.outbox.count == count)
}
@Test func offlineDraftReopensAndQueuedChangesRemainUnsent() async throws {
  let root = try folder()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try WorkspaceRepository(directory: root)
  var state = try await store.transact {
    try $0.createProject(title: "Actual local test project", site: "No server")
  }
  let project = try #require(state.projects.first?.id)
  let draft = EntryDraft(projectID: project, title: "", note: "Unsaved form content preserved\n")
  state = try await store.transact {
    try $0.saveDraft(draft)
    $0.restoration.openDraftID = draft.id
  }
  let expected = state
  await store.close()
  let reopened = try WorkspaceRepository(directory: root)
  #expect(await reopened.snapshot() == expected)
  #expect(expected.entries.isEmpty)
  #expect(expected.outbox.count == 1)
  #expect(expected.outbox[0].idempotencyKey == expected.outbox[0].id.uuidString.lowercased())
  await reopened.close()
}
@Test func staleAndInvalidMutationsLeaveStateIntact() async throws {
  let root = try folder()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try WorkspaceRepository(directory: root)
  let old = await store.snapshot()
  let state = try await store.transact { try $0.createProject(title: "Site", site: "") }
  await #expect(throws: FieldLogError.self) {
    try await store.transact(expectedRevision: old.revision) {
      try $0.createProject(title: "Stale", site: "")
    }
  }
  await #expect(throws: FieldLogError.self) { try await store.transact { $0.schema = 999 } }
  #expect(await store.snapshot() == state)
  await store.close()
}
@Test func concurrentOperationsDoNotOverwriteOneAnother() async throws {
  let root = try folder()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try WorkspaceRepository(directory: root)
  let first = try await store.transact { try $0.createProject(title: "Site", site: "") }
  let id = try #require(first.projects.first?.id)
  try await withThrowingTaskGroup(of: Void.self) { group in
    for i in 0..<20 {
      group.addTask {
        _ = try await store.transact {
          try $0.saveTask(projectID: id, title: "Task \(i)", responsible: "")
        }
      }
    }
    try await group.waitForAll()
  }
  let state = await store.snapshot()
  #expect(state.tasks.count == 20 && state.outbox.count == 21)
  #expect(Set(state.outbox.map(\.id)).count == 21)
  #expect(state.revision == 21)
  await store.close()
}
@Test func commitFaultsReopenPreviousOrCompleteNextState() async throws {
  for point in [
    "before_write", "before_file_sync", "before_rename", "after_rename", "after_directory_sync",
  ] {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try WorkspaceRepository(directory: root)
    await initial.close()
    let store = try WorkspaceRepository(
      directory: root, fault: { if $0 == point { throw FieldLogError.storage("injected ENOSPC") } })
    await #expect(throws: FieldLogError.self) {
      try await store.transact { try $0.createProject(title: "Committed atomically", site: "") }
    }
    await #expect(throws: FieldLogError.self) {
      try await store.transact { try $0.createProject(title: "Must restart", site: "") }
    }
    await store.close()
    let reopened = try WorkspaceRepository(directory: root)
    let state = await reopened.snapshot()
    let committed = point == "after_rename" || point == "after_directory_sync"
    #expect(state.projects.count == (committed ? 1 : 0))
    #expect(state.outbox.count == (committed ? 1 : 0))
    #expect(state.revision == (committed ? 1 : 0))
    await reopened.close()
  }
}
@Test func corruptOrUnknownSchemaIsNeverReset() async throws {
  for data in [
    Data("broken".utf8),
    try JSONEncoder().encode(
      {
        var w = Workspace()
        w.schema = 999
        return w
      }()),
  ] {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workspace.json")
    try data.write(to: file)
    #expect(throws: FieldLogError.self) { try WorkspaceRepository(directory: root) }
    #expect(try Data(contentsOf: file) == data)
  }
}
@Test func externalSnapshotReplacementCannotBeOverwritten() async throws {
  let root = try folder()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try WorkspaceRepository(directory: root)
  let altered = Workspace()
  let bytes = try JSONEncoder().encode(altered)
  try bytes.write(to: root.appendingPathComponent("workspace.json"))
  await #expect(throws: FieldLogError.self) {
    try await store.transact { try $0.createProject(title: "Cannot overwrite", site: "") }
  }
  #expect(try Data(contentsOf: root.appendingPathComponent("workspace.json")) == bytes)
  await store.close()
}
@Test func photoReferencesArePrivateBoundedAndDurable() async throws {
  let root = try folder()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try WorkspaceRepository(directory: root)
  let first = try await store.transact { try $0.createProject(title: "Site", site: "") }
  let id = try #require(first.projects.first?.id)
  let draft = EntryDraft(projectID: id)
  _ = try await store.transact { try $0.saveDraft(draft) }
  await #expect(throws: FieldLogError.self) {
    try await store.addPhoto(jpeg: Data("not JPEG".utf8), to: draft.id)
  }
  let bytes = Data([0xff, 0xd8, 0xff, 0x01])
  let state = try await store.addPhoto(jpeg: bytes, to: draft.id)
  let photo = try #require(state.attachments.first)
  let url = try await store.photoURL(photo.id)
  #expect(try Data(contentsOf: url) == bytes)
  #expect(url.deletingLastPathComponent().lastPathComponent == "photos")
  var invalid = state
  invalid.attachments[0].filename = "../workspace.json"
  #expect(throws: FieldLogError.self) { try invalid.validate() }
  try Data([0]).write(to: url)
  await #expect(throws: (any Error).self) { try await store.photoURL(photo.id) }
  await store.close()
}
@Test func reportSharesActualRecordsAndDisclosesLocalScope() throws {
  var state = Workspace()
  var id = UUID()
  try mutate(&state) { id = try $0.createProject(title: "Site record", site: "North gate") }
  try mutate(&state) { try $0.saveTask(projectID: id, title: "Measure opening", responsible: "") }
  let draft = EntryDraft(projectID: id, title: "Check-in", note: "Keep this exact note.")
  try mutate(&state) {
    try $0.saveDraft(draft)
    try $0.commitDraft(draft.id)
  }
  let report = try state.report(projectID: id)
  #expect(
    report.contains("Site record") && report.contains("Measure opening")
      && report.contains("Keep this exact note."))
  #expect(report.contains("local records only"))
  #expect(!report.contains("Uploaded"))
}
