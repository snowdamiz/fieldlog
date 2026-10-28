import Foundation
import Testing
import MixerUI
import FieldLogModels
import FieldLogStorage
import FieldLogFeatures

private actor PresentationSaveGate {
  private(set) var calls: [(String, String)] = []
  private var continuation: CheckedContinuation<TaskSaveResult, Never>?
  private var admission: CheckedContinuation<Void, Never>?
  func save(_ title: String, _ responsible: String) async -> TaskSaveResult {
    calls.append((title, responsible))
    return await withCheckedContinuation {
      continuation = $0
      admission?.resume(); admission = nil
    }
  }
  func waitForAdmission() async {
    if continuation != nil { return }
    await withCheckedContinuation { admission = $0 }
  }
  func finish(_ result: TaskSaveResult) {
    continuation?.resume(returning: result); continuation = nil
  }
}

@MainActor private func event(_ form: TaskEditorPresentation, _ id: String,
  _ kind: UIEventKind = .activate, _ value: UIValue = .null) throws -> UIEventEnvelope
{
  UIEventEnvelope(revision: form.snapshot.render.document.revision,
    identity: try #require(form.snapshot.render.identity(for: id)), event: kind, value: value)
}

private func node(_ snapshot: TaskEditorPresentationSnapshot, _ id: String) -> UINode? {
  var pending = [snapshot.render.document.root]
  while let value = pending.popLast() {
    if value.id == id { return value }
    pending.append(contentsOf: value.children)
  }
  return nil
}

@Test @MainActor func taskPresentationRoutesRealRepositorySaveAndFinishesNavigationAfterDurability() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fieldlog-presentation-\(UUID())")
  defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let initial = try await repository.transact { try $0.createProject(title: "Shared task flow", site: "") }
  let projectID = try #require(initial.projects.first?.id)
  let form = try TaskEditorPresentation { title, responsible in
    do {
      _ = try await repository.transact {
        try $0.saveTask(projectID: projectID, title: title, responsible: responsible)
      }
      return .saved
    } catch { return .failed(error.localizedDescription) }
  }
  #expect(form.snapshot.navigation.routes.map(\.name) == ["newTask"])
  let exactTitle = "  Measure  日本語\nopening 🧪  "
  try form.send(event(form, "task.title", .textChange, .string(exactTitle)))
  try form.send(event(form, "task.responsible", .textChange, .string("  Rae  ")))
  #expect(node(form.snapshot, "task.title")?.properties["value"]?.string == exactTitle)
  try form.send(event(form, "task.save"))
  #expect(form.snapshot.outcome == .editing && form.snapshot.state.saving)
  #expect(!form.snapshot.navigation.routes.isEmpty)
  await form.waitForSave()
  #expect(form.snapshot.outcome == .saved && form.snapshot.navigation.routes.isEmpty)
  let committed = await repository.snapshot()
  #expect(committed.tasks.count == 1 && committed.outbox.count == 2)
  #expect(committed.tasks.first?.title == "Measure  日本語\nopening 🧪")
  #expect(committed.tasks.first?.responsible == "Rae")
  #expect(throws: TaskEditorPresentationError.closed) { try form.send(event(form, "task.save")) }
  try form.close()
  await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect(await reopened.snapshot() == committed)
  await reopened.close()
}

@Test @MainActor func taskPresentationInvalidInputKeepsExactTextAndShowsSharedFailure() async throws {
  let gate = PresentationSaveGate()
  let form = try TaskEditorPresentation { await gate.save($0, $1) }
  try form.send(nodeID: "task.title", event: .textChange, value: .string(" \n "))
  #expect(throws: UIRoutingError.disabledNode) { try form.send(event(form, "task.save")) }
  let invalid = String(repeating: "🧪", count: 241)
  try form.send(nodeID: "task.title", event: .textChange, value: .string(invalid))
  try form.send(nodeID: "task.save", event: .activate)
  #expect(form.snapshot.state.title == invalid && form.snapshot.state.failure != nil)
  #expect(node(form.snapshot, "task.failure.message")?.properties["text"]?.string == form.snapshot.state.failure)
  #expect(await gate.calls.isEmpty)
  try form.send(nodeID: "task.title", event: .textChange, value: .string("Corrected task"))
  #expect(form.snapshot.state.failure == nil && node(form.snapshot, "task.failure.message") == nil)
  try form.send(nodeID: "task.responsible", event: .textChange, value: .string(String(repeating: "r", count: 161)))
  try form.send(nodeID: "task.save", event: .activate)
  #expect(form.snapshot.state.responsible.count == 161 && form.snapshot.state.failure != nil)
  #expect(await gate.calls.isEmpty)
  try form.close()
}

@Test @MainActor func taskPresentationHeldSaveDisablesAllActionsAndFailureAllowsExactRetry() async throws {
  let gate = PresentationSaveGate()
  let form = try TaskEditorPresentation { await gate.save($0, $1) }
  let title = "  Keep  東京\nexact  "
  try form.send(nodeID: "task.title", event: .textChange, value: .string(title))
  try form.send(nodeID: "task.responsible", event: .textChange, value: .string("  Jo  "))
  try form.send(nodeID: "task.save", event: .activate)
  await gate.waitForAdmission()
  for (id, kind, value) in [
    ("task.title", UIEventKind.textChange, UIValue.string("Changed")),
    ("task.responsible", .textChange, .string("Changed")),
    ("task.save", .activate, .null), ("task.cancel", .activate, .null)
  ] {
    #expect(throws: UIRoutingError.disabledNode) { try form.send(event(form, id, kind, value)) }
  }
  #expect(await gate.calls.count == 1)
  await gate.finish(.failed("Disk is full"))
  await form.waitForSave()
  #expect(form.snapshot.outcome == .editing && form.snapshot.state.title == title)
  #expect(form.snapshot.state.responsible == "  Jo  " && form.snapshot.state.failure == "Disk is full")
  #expect(node(form.snapshot, "task.save")?.properties["disabled"]?.bool == false)
  try form.send(nodeID: "task.save", event: .activate)
  await gate.waitForAdmission()
  #expect(await gate.calls.count == 2)
  await gate.finish(.saved)
  await form.waitForSave()
  #expect(form.snapshot.outcome == .saved)
  try form.close()
}

@Test @MainActor func taskPresentationRejectsStaleForeignAndWrongValueEventsWithoutMutation() throws {
  let form = try TaskEditorPresentation { _, _ in .failed("Must not save") }
  let stale = try event(form, "task.title", .textChange, .string("Stale"))
  try form.send(nodeID: "task.title", event: .textChange, value: .string("Current"))
  let current = form.snapshot
  #expect(throws: UIRoutingError.staleRevision) { try form.send(stale) }
  let wrongIdentity = UIEventEnvelope(revision: current.render.document.revision,
    identity: UINodeIdentity(id: "task.title", generation: UInt64.max), event: .textChange, value: .string("Foreign"))
  #expect(throws: UIRoutingError.staleIdentity) { try form.send(wrongIdentity) }
  #expect(throws: UIRoutingError.invalidValue) {
    try form.send(event(form, "task.title", .textChange, .bool(true)))
  }
  #expect(throws: UIRoutingError.unboundEvent) {
    try form.send(event(form, "task.title", .activate))
  }
  #expect(throws: UIRoutingError.invalidValue) {
    try form.send(event(form, "task.title", .textChange, .string(String(repeating: "a", count: 16_385))))
  }
  #expect(form.snapshot.state == current.state)
  #expect(form.snapshot.render.document == current.render.document)
  try form.close()
}

@Test @MainActor func taskPresentationCancelPopsSharedRouteWithoutCallingPersistence() async throws {
  let gate = PresentationSaveGate()
  let form = try TaskEditorPresentation { await gate.save($0, $1) }
  try form.send(nodeID: "task.title", event: .textChange, value: .string("Unsaved task"))
  try form.send(nodeID: "task.cancel", event: .activate)
  #expect(form.snapshot.outcome == .cancelled && form.snapshot.navigation.routes.isEmpty)
  #expect(form.snapshot.state.title == "Unsaved task")
  #expect(await gate.calls.isEmpty)
  #expect(throws: TaskEditorPresentationError.closed) {
    try form.send(nodeID: "task.save", event: .activate)
  }
  try form.close()
  #expect(form.snapshot.outcome == .cancelled)
}

@Test @MainActor func taskPresentationCloseRejectsLateSaveAndNewEvents() async throws {
  let gate = PresentationSaveGate()
  let form = try TaskEditorPresentation { await gate.save($0, $1) }
  try form.send(nodeID: "task.title", event: .textChange, value: .string("Late result"))
  try form.send(nodeID: "task.save", event: .activate)
  await gate.waitForAdmission()
  try form.close()
  let closed = form.snapshot
  await gate.finish(.saved)
  await Task.yield()
  #expect(form.snapshot.outcome == .closed && !form.snapshot.state.saved)
  #expect(form.snapshot.state == closed.state && form.snapshot.navigation.routes.isEmpty)
  #expect(throws: TaskEditorPresentationError.closed) {
    try form.send(nodeID: "task.title", event: .textChange, value: .string("After close"))
  }
  try form.close()
}

@Test @MainActor func taskPresentationStorageFailureDoesNotInventDurableSuccess() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fieldlog-presentation-fault-\(UUID())")
  defer { try? FileManager.default.removeItem(at: folder) }
  let seed = try WorkspaceRepository(directory: folder)
  let initial = try await seed.transact { try $0.createProject(title: "Preserved workspace", site: "") }
  let projectID = try #require(initial.projects.first?.id)
  await seed.close()
  let repository = try WorkspaceRepository(directory: folder, fault: { point in
    if point == "before_rename" { throw FieldLogError.storage("Unable to commit") }
  })
  let form = try TaskEditorPresentation { title, responsible in
    do {
      _ = try await repository.transact { try $0.saveTask(projectID: projectID, title: title, responsible: responsible) }
      return .saved
    } catch { return .failed(error.localizedDescription) }
  }
  let title = " Keep\n  exact "
  try form.send(nodeID: "task.title", event: .textChange, value: .string(title))
  try form.send(nodeID: "task.save", event: .activate)
  await form.waitForSave()
  #expect(form.snapshot.outcome == .editing && form.snapshot.state.failure != nil)
  #expect(form.snapshot.state.title == title && !form.snapshot.navigation.routes.isEmpty)
  try form.close()
  await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect(await reopened.snapshot() == initial)
  await reopened.close()
}

@Test @MainActor func taskPresentationBoundsRenderedDiagnosticWithoutLosingFailureState() async throws {
  let failure = String(repeating: "🧪", count: 10_000)
  let form = try TaskEditorPresentation { _, _ in .failed(failure) }
  try form.send(nodeID: "task.title", event: .textChange, value: .string("Preserve input"))
  try form.send(nodeID: "task.save", event: .activate)
  await form.waitForSave()
  #expect(form.snapshot.state.failure == failure && form.snapshot.renderingFailure == nil)
  #expect(node(form.snapshot, "task.failure.message")?.properties["text"]?.string?.count == 1000)
  _ = try UIValidator().validate(form.snapshot.render.document)
  try form.close()
}

@Test @MainActor func taskPresentationBoundsASingleLargeCombiningClusterByUTF8Bytes() async throws {
  let failure = "a" + String(repeating: "\u{0301}", count: 10_000)
  #expect(failure.count == 1 && failure.utf8.count > 16_384)
  let form = try TaskEditorPresentation { _, _ in .failed(failure) }
  try form.send(nodeID: "task.title", event: .textChange, value: .string("Keep the form usable"))
  try form.send(nodeID: "task.save", event: .activate)
  await form.waitForSave()
  #expect(form.snapshot.state.failure == failure && form.snapshot.renderingFailure == nil)
  let displayed = try #require(node(form.snapshot, "task.failure.message")?.properties["text"]?.string)
  #expect(displayed.utf8.count <= 4002)
  _ = try UIValidator().validate(form.snapshot.render.document)
  #expect(node(form.snapshot, "task.save")?.properties["disabled"]?.bool == false)
  try form.close()
}
