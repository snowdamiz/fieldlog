import Foundation
import Testing
import FieldLogModels
import FieldLogStorage
import FieldLogFeatures

private actor SaveGate {
  var calls: [(String, String)] = []
  private var continuation: CheckedContinuation<TaskSaveResult, Never>?
  private var admission: CheckedContinuation<Void, Never>?
  func save(_ title: String, _ responsible: String) async -> TaskSaveResult {
    calls.append((title, responsible))
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      admission?.resume(); admission = nil
    }
  }
  func waitForAdmission() async {
    if !calls.isEmpty { return }
    await withCheckedContinuation { admission = $0 }
  }
  func finish(_ result: TaskSaveResult) { continuation?.resume(returning: result); continuation = nil }
}

@Test @MainActor func taskEditorPreservesTextAndRejectsInvalidSubmission() async throws {
  let gate = SaveGate()
  let editor = try TaskEditor { await gate.save($0, $1) }
  try editor.changeTitle("  \n")
  try editor.submit()
  #expect(!editor.state.canSubmit && !editor.state.saving)
  try editor.changeTitle(String(repeating: "a", count: 241))
  try editor.submit()
  #expect(editor.state.failure != nil && !editor.state.saving)
  #expect(editor.state.title.count == 241)
  #expect(await gate.calls.isEmpty)
  try editor.close()
}

@Test @MainActor func taskEditorAdmitsOneSaveAndRetainsFailedInputForRetry() async throws {
  let gate = SaveGate()
  let editor = try TaskEditor { await gate.save($0, $1) }
  let title = "  Measure  日本語 opening  "
  try editor.changeTitle(title)
  try editor.changeResponsible("  Rae  ")
  try editor.submit()
  await gate.waitForAdmission()
  try editor.submit()
  try editor.changeTitle("Editing while save owns the form")
  #expect(editor.state.saving && editor.state.title == title)
  #expect(await gate.calls.count == 1)
  await gate.finish(.failed("Disk is full"))
  await editor.waitForSave()
  #expect(editor.state.failure == "Disk is full")
  #expect(editor.state.title == title && editor.state.responsible == "  Rae  ")
  #expect(editor.state.canSubmit && !editor.state.saved)
  try editor.close()
}

@Test @MainActor func taskEditorClosedOwnerCannotReceiveLateSaveSuccess() async throws {
  let gate = SaveGate()
  let editor = try TaskEditor { await gate.save($0, $1) }
  try editor.changeTitle("Late result")
  try editor.submit()
  await gate.waitForAdmission()
  let beforeClose = editor.state
  try editor.close()
  await gate.finish(.saved)
  // The underlying operation deliberately ignores cancellation. Closing the
  // public Mixer owner rejects its result without claiming to undo persistence.
  await Task.yield()
  #expect(editor.state == beforeClose && !editor.state.saved)
  #expect(throws: (any Error).self) { try editor.submit() }
}

@Test @MainActor func publishedMixerTaskFeatureCommitsThroughExistingRepositoryAndReopens() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fieldlog-public-package-\(UUID())")
  defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let original = try await repository.transact { try $0.createProject(title: "Package consumer", site: "") }
  let project = try #require(original.projects.first?.id)
  let editor = try TaskEditor { title, responsible in
    do {
      _ = try await repository.transact { try $0.saveTask(projectID: project, title: title, responsible: responsible) }
      return .saved
    } catch { return .failed(error.localizedDescription) }
  }
  try editor.changeTitle("  Measure  日本語 opening  ")
  try editor.changeResponsible("Rae")
  try editor.submit()
  await editor.waitForSave()
  #expect(editor.state.saved && !editor.state.saving && !editor.state.canSubmit)
  try editor.submit()
  let committed = await repository.snapshot()
  #expect(committed.tasks.count == 1 && committed.outbox.count == 2)
  #expect(committed.tasks.first?.title == "Measure  日本語 opening")
  try editor.close()
  await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect(await reopened.snapshot() == committed)
  await reopened.close()
}
