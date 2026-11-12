import Foundation
import XCTest
import FieldLogFeatures
@testable import FieldLogAndroid
import FieldLogModels
import FieldLogStorage
import MixerUI
import MixerAndroid

enum ReviewError: Error { case failed(String), surface }
func check(_ truth: @autoclosure () throws -> Bool, _ label: String) throws {
    if try !truth() { throw ReviewError.failed(label) }
}
func rejects(_ label: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw ReviewError.failed("Accepted: " + label)
}
@MainActor final class R109Surface: AndroidUINativeSurface {
    let profile = AndroidUIProfile.measuredMultilineLongNotesV4
    var capabilities: AndroidUICapabilities { profile.capabilities }
    var owner: UUID?
    var frames: [AndroidUIFrame] = []
    var refuse = false
    func activate(owner: UUID) throws { try check(self.owner == nil, "one owner"); self.owner = owner }
    func install(_ frame: AndroidUIFrame) throws {
        try check(frame.owner == owner, "frame owner")
        if refuse { throw ReviewError.surface }
        // Use the real public decoder rather than a plain Codable fixture.
        let object = try JSONSerialization.jsonObject(with: frame.packet) as! [String: Any]
        _ = try UIDocument.decode(JSONSerialization.data(withJSONObject: object["document"]!), validator: UIValidator(supportedTextFieldAxes: profile.capabilities.textFieldAxes, textValuePolicy: profile.textValuePolicy))
        frames.append(frame)
    }
    func revoke(owner: UUID) { precondition(owner == self.owner); self.owner = nil }
}
@MainActor func event(_ app: PublicAndroidApplication, _ id: String, _ kind: UIEventKind = .activate, _ value: UIValue = .null) throws -> UIEventEnvelope {
    let s = app.presentation.snapshot
    guard let identity = s.identity(for: id) else { throw ReviewError.failed("Missing node " + id) }
    return UIEventEnvelope(revision: s.document.revision, identity: identity, event: kind, value: value)
}
@MainActor func send(_ app: PublicAndroidApplication, _ id: String, _ kind: UIEventKind = .activate, _ value: UIValue = .null) throws {
    try app.send(owner: app.host.owner!, originalEnvelope: JSONEncoder().encode(event(app, id, kind, value)))
}
func file(_ directory: URL) -> URL { directory.appendingPathComponent("FieldLog/workspace.json") }
func disk(_ directory: URL) throws -> Workspace { try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file(directory))) }
@MainActor func open(_ directory: URL, _ surface: R109Surface = R109Surface()) async throws -> PublicAndroidApplication {
    try await PublicAndroidApplication(surface: surface, selectedProfile: surface.profile.rawValue, directory: directory)
}
@MainActor func typeTask(_ app: PublicAndroidApplication, _ title: String, _ responsible: String = "") throws {
    try send(app, "task.title", .textChange, .string(title))
    try send(app, "task.responsible", .textChange, .string(responsible))
}
@MainActor func text(_ app: PublicAndroidApplication) throws -> String {
    String(decoding: try JSONEncoder().encode(app.presentation.snapshot.document), as: UTF8.self)
}
@MainActor func core(_ root: URL) async throws {
    let dir = root.appendingPathComponent("core")
    let surface = R109Surface(), app = try await open(dir, surface)
    try typeTask(app, "Same title", "Jo")
    let captured = app.presentation.snapshot, title = try event(app, "task.title", .textChange, .string("must not leak"))
    let save = try event(app, "task.save"), queue = try event(app, "workspace.queue")
    let prior = try Data(contentsOf: file(dir)), oldState = app.presentation.state, frames = surface.frames.count
    for batch in [[title, save, title], [title, queue], [queue, save]] {
        try rejects("invalid original mixed batch") { try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode(batch)) }
        try check(app.presentation.snapshot.document == captured.document && app.presentation.state == oldState, "rejected batch state")
        try check(Data(contentsOf: file(dir)) == prior && surface.frames.count == frames, "rejected batch disk/frame")
    }
    try rejects("foreign owner") { try app.send(owner: UUID(), originalEnvelope: JSONEncoder().encode(title)) }
    let bad = try event(app, "task.save", .activate, .string("wrong value"))
    try rejects("wrong value") { try app.send(owner: app.host.owner!, originalEnvelope: JSONEncoder().encode(bad)) }
    try send(app, "task.save")
    try check(Data(contentsOf: file(dir)) == prior, "no disk before yielding busy frame")
    try rejects("busy original event") { try app.send(owner: app.host.owner!, originalEnvelope: JSONEncoder().encode(title)) }
    try await app.settle()
    try check(app.presentation.state.saved && app.presentation.workspace.tasks.count == 1, "first save")
    try send(app, "task.new"); try typeTask(app, "Same title", "Sam"); try send(app, "task.save"); try await app.settle()
    let tasks = app.presentation.workspace.tasks, ids = tasks.map(\.id)
    try check(Set(ids).count == 2 && tasks.map(\.responsible) == ["Jo", "Sam"], "same title does not overwrite")
    let one = "task." + ids[0].uuidString.lowercased(), two = "task." + ids[1].uuidString.lowercased()
    let stale = try event(app, one + ".complete")
    try send(app, one + ".complete"); try await app.settle()
    try check(app.presentation.workspace.tasks.first { $0.id == ids[0] }!.completed, "complete identity")
    try rejects("stale original generation") { try app.send(owner: app.host.owner!, originalEnvelope: JSONEncoder().encode(stale)) }
    try send(app, two + ".up"); try await app.settle()
    let project = tasks[0].projectID
    try check(app.presentation.workspace.tasks(for: project).map(\.id) == [ids[1], ids[0]], "reorder IDs")
    try rejects("disabled edge") { try send(app, two + ".up") }
    try send(app, "task.new"); try typeTask(app, "Draft retained", "Unsubmitted")
    try send(app, "workspace.queue")
    let q = try text(app)
    try check(q.contains("Not sent") && q.contains("Nothing in this queue has been sent to a server.") && q.contains("Pending changes (5)"), "real unsent queue")
    try rejects("hidden editor stale envelope") { try app.send(owner: app.host.owner!, originalEnvelope: JSONEncoder().encode(title)) }
    try send(app, "workspace.back")
    try check(app.presentation.state.title == "Draft retained" && app.presentation.state.responsible == "Unsubmitted", "queue keeps editor")
    let owner = app.host.owner!
    try send(app, one + ".complete"); await app.close()
    try check(surface.owner == nil, "owner revoked")
    let saved = try disk(dir)
    try check(saved.outbox.count == 6 && !saved.tasks.first { $0.id == ids[0] }!.completed, "close drains workspace write")
    let reopened = try await open(dir)
    try check(reopened.presentation.workspace == saved, "fresh repository matches exact saved workspace")
    try rejects("old owner after close") { try reopened.send(owner: owner, originalEnvelope: JSONEncoder().encode(stale)) }
    try typeTask(reopened, "Close drains task", "Lee"); try send(reopened, "task.save"); await reopened.close()
    try check(disk(dir).tasks.count == 3 && disk(dir).outbox.count == 7, "close drains editor write")
    print("PASS core: original/mixed/stale/foreign/wrong-value admission; two same-title IDs; complete/reopen/reorder; queue retains draft; Close drains both write types")
}
@MainActor func failureControls(_ root: URL) async throws {
    let dir = root.appendingPathComponent("failures"), app = try await open(dir)
    let prior = try Data(contentsOf: file(dir))
    try typeTask(app, String(repeating: "x", count: 241), "Keep me")
    try send(app, "task.save"); try await app.settle()
    try check(app.presentation.state.failure != nil && !app.presentation.state.saving && !app.presentation.state.saved, "invalid model has failure")
    try check(Data(contentsOf: file(dir)) == prior && app.presentation.state.title.utf8.count == 241, "invalid model keeps exact input and disk")
    let previousState = app.presentation.state, previousSnapshot = app.presentation.snapshot
    try rejects("render overlong field before mutation") { try send(app, "task.title", .textChange, .string(String(repeating: "z", count: 16385))) }
    try check(app.presentation.state == previousState && app.presentation.snapshot.document == previousSnapshot.document && Data(contentsOf: file(dir)) == prior, "render rejection atomic")
    try typeTask(app, "Retry exact", "Same person")
    // A real disk read fault, without modifying app business source or injecting a repository.
    let held = file(dir).appendingPathExtension("review-preserved")
    try FileManager.default.moveItem(at: file(dir), to: held)
    try send(app, "task.save"); try await app.settle()
    try check(app.presentation.state.failure != nil && !app.presentation.state.saved && app.presentation.state.title == "Retry exact", "I/O failure keeps input")
    try check(app.presentation.workspace.tasks.isEmpty && app.presentation.workspace.outbox.count == 1 && Data(contentsOf: held) == prior, "I/O failure keeps records/outbox")
    try FileManager.default.moveItem(at: held, to: file(dir))
    try send(app, "task.save"); try await app.settle()
    try check(disk(dir).tasks.count == 1 && disk(dir).outbox.count == 2, "exact retry once")
    let task = app.presentation.workspace.tasks[0], key = "task." + task.id.uuidString.lowercased() + ".complete"
    let beforeEdit = try Data(contentsOf: file(dir))
    try FileManager.default.moveItem(at: file(dir), to: held)
    try send(app, key); try await app.settle()
    try check(!app.presentation.workspace.tasks[0].completed && app.presentation.workspace.outbox.count == 2 && Data(contentsOf: held) == beforeEdit, "failed workspace write preserves records/outbox")
    try check(text(app).contains("file") || text(app).contains("exist"), "storage failure published")
    try FileManager.default.moveItem(at: held, to: file(dir))
    try send(app, key); try await app.settle()
    try check(disk(dir).tasks[0].completed && disk(dir).outbox.count == 3, "workspace retry once")
    await app.close()
    print("PASS failures: invalid model and oversized render before I/O; real disk read failures retain exact editor, records and outbox; retries commit once")
}
@MainActor func publicationFailure(_ root: URL) async throws {
    let dir = root.appendingPathComponent("surface"), surface = R109Surface(), app = try await open(dir, surface)
    try typeTask(app, "Retained despite rejected publication", "Jo")
    surface.refuse = true
    try rejects("surface refuses busy install") { try send(app, "task.save") }
    var reported = false
    do { try await app.settle() } catch { reported = true }
    try check(reported, "publication error surfaced")
    try check(app.presentation.state.saved && disk(dir).tasks.count == 1 && disk(dir).outbox.count == 2, "admitted save survives publication refusal exactly once")
    await app.close()
    let reopened = try await open(dir)
    try check(reopened.presentation.workspace.tasks[0].title == "Retained despite rejected publication", "publication failure durable reopen")
    await reopened.close()
    print("PASS publication: refused native install reports error, admitted save remains durable exactly once and reopens")
}
@MainActor func scopeControl(_ root: URL) async throws {
    let dir = root.appendingPathComponent("projects"), repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
    let baseline = try await repo.transact { w in
        let a = try w.createProject(title: "A", site: ""), b = try w.createProject(title: "B", site: "")
        try w.saveTask(projectID: a, title: "A1", responsible: "A")
        try w.saveTask(projectID: a, title: "A2", responsible: "A")
        try w.saveTask(projectID: b, title: "B1", responsible: "B")
    }
    await repo.close()
    let app = try await open(dir), bTask = baseline.tasks[2]
    try rejects("foreign project task not in captured document") { try send(app, "task." + bTask.id.uuidString.lowercased() + ".complete") }
    try send(app, "task." + baseline.tasks[0].id.uuidString.lowercased() + ".complete"); try await app.settle()
    try send(app, "task." + baseline.tasks[1].id.uuidString.lowercased() + ".up"); try await app.settle()
    let retainedTask = app.presentation.workspace.tasks.first(where: { $0.id == bTask.id })
    try check(retainedTask == bTask, "other project unchanged")
    await app.close()
    print("PASS project scope: completion/reorder retain task identity and leave other project records untouched")
}
@MainActor func renderBoundary(_ root: URL) async throws {
    let dir = root.appendingPathComponent("boundary"), repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
    _ = try await repo.transact { w in
        let p = try w.createProject(title: "Real repository fixture", site: "")
        for i in 0..<200 { try w.saveTask(projectID: p, title: "Task \(i)", responsible: "Jo") }
    }
    await repo.close()
    let app = try await open(dir), surfaceState = app.presentation.snapshot.document
    try typeTask(app, "Task 201", "Sam"); try send(app, "task.save")
    try check(app.presentation.state.saving, "boundary save admitted")
    var failure = "none"
    do { try await app.settle() } catch { failure = String(describing: error) }
    let saved = try disk(dir)
    try saved.validate()
    try check(saved.tasks.count == 201 && saved.outbox.count == 202, "boundary committed legal model")
    let frame = try text(app)
    print("BOUNDARY task201: settle=\(failure), editor.saved=\(app.presentation.state.saved), snapshot.revision=\(app.presentation.snapshot.document.revision), initial.revision=\(surfaceState.revision), savingFrame=\(frame.contains("Saving")), tasks=\(saved.tasks.count), outbox=\(saved.outbox.count)")
    await app.close()
    var reopenError = "none"
    do { let reopened = try await open(dir); await reopened.close() } catch { reopenError = String(describing: error) }
    print("BOUNDARY task201 fresh reopen: \(reopenError)")
    try check(failure == "none" && reopenError == "none" && !frame.contains("Saving") && app.presentation.state.saved, "task-201 completion and fresh reopen now succeed")
}
final class FieldLogPaginationTests: XCTestCase {
    @MainActor func testR109OriginalConditionsAndIndependentControls() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]!).appendingPathComponent("r109-controls")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await core(root)
        try await failureControls(root)
        try await publicationFailure(root)
        try await scopeControl(root)
        try await renderBoundary(root)
    }
}
