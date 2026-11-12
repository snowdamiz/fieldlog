import Foundation
import XCTest
import FieldLogModels
import FieldLogFeatures
import FieldLogStorage
import MixerUI
import MixerAndroid
@testable import FieldLogAndroid

private func key(_ task: WorkTask) -> String { "task." + task.id.uuidString.lowercased() }
private func nodes(_ node: UINode) -> [UINode] { [node] + node.children.flatMap(nodes) }
@MainActor private func node(_ app: PublicAndroidApplication, _ id: String) throws -> UINode {
    try XCTUnwrap(nodes(app.presentation.snapshot.document.root).first { $0.id == id })
}
@MainActor private func enabled(_ app: PublicAndroidApplication, _ id: String) throws -> Bool {
    try node(app, id).properties["disabled"]?.bool != true
}
@MainActor private func root(_ name: String) -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]!).appendingPathComponent(name)
}

final class PaginationContractTests: XCTestCase {
    @MainActor func testAllPagesGlobalOrderQueueAndExactUnicodeRecords() async throws {
        let dir = root("pagination"), repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
        let title = String(repeating: "🧪", count: 60), responsible = String(repeating: "é", count: 80)
        let baseline = try await repo.transact { w in
            let project = try w.createProject(title: "Pagination", site: "")
            for i in 0..<221 {
                try w.saveTask(projectID: project, title: i == 110 ? title : "Task \(i)", responsible: responsible)
            }
            try w.toggleTask(w.tasks[0].id)
            try w.toggleTask(w.tasks[220].id)
        }
        await repo.close()
        let app = try await open(dir), project = baseline.projects[0].id
        let ordered = baseline.tasks(for: project)
        let beforeNavigation = try Data(contentsOf: file(dir))
        XCTAssertEqual(try node(app, "workspace.progress").properties["text"]?.string, "2 of 221 tasks completed")
        XCTAssertFalse(try enabled(app, "tasks.previous"))
        try rejects("disabled first checklist page") { try send(app, "tasks.previous") }
        let staleNext = try event(app, "tasks.next")
        var seen: [UUID] = [], pageNumber = 0
        repeat {
            let visible = ordered.filter { app.presentation.snapshot.identity(for: key($0) + ".complete") != nil }
            XCTAssertEqual(visible.map(\.id), Array(ordered.dropFirst(pageNumber * 20).prefix(20)).map(\.id))
            XCTAssertLessThanOrEqual(visible.count, 20)
            seen += visible.map(\.id)
            let packet = try app.presentation.snapshot.encodeNativePacketV1(supportedTextFieldAxes: R109Surface().profile.capabilities.textFieldAxes, textValuePolicy: R109Surface().profile.textValuePolicy)
            XCTAssertLessThan(packet.count, 1_048_576)
            XCTAssertLessThanOrEqual(try node(app, "workspace.tasks").children.count, 103)
            if pageNumber == 0 || pageNumber == 5 || pageNumber == 11 {
                print("PAGE checklist: \(try node(app, "tasks.position").properties["text"]!.string!), rows=\(visible.count), packetBytes=\(packet.count)")
            }
            if pageNumber == 5 {
                XCTAssertEqual(try node(app, key(ordered[110]) + ".responsible").properties["text"]?.string, responsible)
                XCTAssertTrue(try node(app, key(ordered[110]) + ".title").properties["text"]!.string!.contains(title))
            }
            if try !enabled(app, "tasks.next") { break }
            try send(app, "tasks.next"); pageNumber += 1
        } while pageNumber < 20
        XCTAssertEqual(pageNumber, 11)
        XCTAssertEqual(seen, ordered.map(\.id))
        try rejects("disabled last checklist page") { try send(app, "tasks.next") }
        try rejects("last global task cannot move down") { try send(app, key(ordered.last!) + ".down") }
        try rejects("stale original page envelope") { try app.send(owner: app.host.owner!, originalEnvelope: JSONEncoder().encode(staleNext)) }
        XCTAssertEqual(try Data(contentsOf: file(dir)), beforeNavigation)
        while try enabled(app, "tasks.previous") { try send(app, "tasks.previous") }
        let moved = ordered[19]
        try send(app, key(moved) + ".down"); try await app.settle()
        var expected = ordered.map(\.id); expected.swapAt(19, 20)
        XCTAssertEqual(app.presentation.workspace.tasks(for: project).map(\.id), expected)
        XCTAssertNotNil(app.presentation.snapshot.identity(for: key(moved) + ".complete"), "Moved task follows global destination onto page 2")
        XCTAssertTrue(try node(app, "tasks.position").properties["text"]!.string!.contains("Page 2 of 12"))
        try send(app, key(moved) + ".up"); try await app.settle()
        XCTAssertEqual(app.presentation.workspace.tasks(for: project).map(\.id), ordered.map(\.id))
        XCTAssertNotNil(app.presentation.snapshot.identity(for: key(moved) + ".complete"))
        XCTAssertTrue(try node(app, "tasks.position").properties["text"]!.string!.contains("Page 1 of 12"))
        try rejects("first global task cannot move up") { try send(app, key(ordered[0]) + ".up") }
        try send(app, key(ordered[0]) + ".complete"); try await app.settle()
        XCTAssertEqual(try node(app, "workspace.progress").properties["text"]?.string, "1 of 221 tasks completed")
        let afterEdits = app.presentation.workspace
        XCTAssertEqual(afterEdits.outbox.count, baseline.outbox.count + 3)
        XCTAssertEqual(Array(afterEdits.outbox.suffix(3)).map(\.kind), [.taskOrderChanged, .taskOrderChanged, .taskSaved])
        XCTAssertEqual(Array(afterEdits.outbox.prefix(baseline.outbox.count)), baseline.outbox)
        XCTAssertEqual(afterEdits.tasks.first { $0.id == ordered[110].id }?.title, title)
        XCTAssertEqual(afterEdits.tasks.first { $0.id == ordered[110].id }?.responsible, responsible)
        try typeTask(app, "Draft 🧪\nretained", "Zoë")
        let draft = app.presentation.state
        try send(app, "workspace.queue")
        XCTAssertFalse(try enabled(app, "queue.previous"))
        try rejects("disabled first queue page") { try send(app, "queue.previous") }
        let queueOrder = Array(afterEdits.outbox.reversed())
        var pending: [UUID] = [], queueNumber = 0
        repeat {
            let visible = queueOrder.filter { app.presentation.snapshot.identity(for: "pending." + $0.id.uuidString.lowercased()) != nil }
            XCTAssertEqual(visible.map(\.id), Array(queueOrder.dropFirst(queueNumber * 20).prefix(20)).map(\.id))
            XCTAssertLessThanOrEqual(try node(app, "queue.changes").children.count, 23)
            pending += visible.map(\.id)
            if queueNumber == 0 || queueNumber == 5 || queueNumber == 11 {
                print("PAGE outbox: \(try node(app, "queue.position").properties["text"]!.string!), rows=\(visible.count)")
            }
            if try !enabled(app, "queue.next") { break }
            try send(app, "queue.next"); queueNumber += 1
        } while queueNumber < 20
        XCTAssertEqual(pending, queueOrder.map(\.id))
        XCTAssertEqual(Set(pending).count, afterEdits.outbox.count)
        XCTAssertFalse(try enabled(app, "queue.next"))
        try rejects("disabled last queue page") { try send(app, "queue.next") }
        XCTAssertTrue(try text(app).contains("Not sent"))
        try send(app, "workspace.back")
        XCTAssertEqual(app.presentation.state, draft)
        XCTAssertEqual(try disk(dir), afterEdits)
        await app.close()
        let reopened = try await open(dir)
        XCTAssertEqual(reopened.presentation.workspace, afterEdits)
        await reopened.close()
        print("PASS pagination: every task and pending change reachable in exact order; edge/stale refusal; global boundary reorder follows task; full 240/160-byte Unicode preserved; draft and exact disk reopen preserved")
    }

    @MainActor func testPrecommitProjectionFailureLeavesSnapshotBytesUntouched() async throws {
        let dir = root("precommit"), app = try await open(dir)
        let project = app.presentation.workspace.projects[0].id
        var reconciler = UIReconciler(validator: UIValidator(supportedTextFieldAxes: R109Surface().profile.capabilities.textFieldAxes, textValuePolicy: R109Surface().profile.textValuePolicy))
        try reconciler.apply(app.presentation.snapshot.document)
        let base = reconciler, before = try Data(contentsOf: file(dir))
        await app.close()
        let repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
        var invalid = TaskEditorState(); invalid.title = String(repeating: "z", count: 16_385); invalid.saving = true
        let invalidState = invalid
        var refused = false
        do {
            _ = try await repo.transact { next in
                try next.saveTask(projectID: project, title: "Actual generated ID before refused projection", responsible: "Jo")
                try ProjectPresentation.preflight(next, state: invalidState, project: project, taskPage: 0, queuePage: 0, reconciler: base)
            }
        } catch UIValidationError.limitExceeded("stringBytes") { refused = true }
        XCTAssertTrue(refused)
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        let unchanged = await repo.snapshot()
        XCTAssertEqual(unchanged, try disk(dir))
        XCTAssertTrue(unchanged.tasks.isEmpty)
        var valid = TaskEditorState(); valid.title = "Actual generated ID"; valid.saving = true
        let validState = valid
        let committed = try await repo.transact { next in
            try next.saveTask(projectID: project, title: validState.title, responsible: "Jo")
            try ProjectPresentation.preflight(next, state: validState, project: project, taskPage: 0, queuePage: 0, reconciler: base)
        }
        XCTAssertEqual(committed.tasks.count, 1)
        XCTAssertEqual(committed.outbox.count, 2)
        XCTAssertEqual(committed.outbox.last?.recordID, committed.tasks[0].id)
        XCTAssertEqual(try disk(dir), committed)
        await repo.close()
        print("PASS precommit: real transaction generates IDs, public projection rejects before file change; same transaction path then validates busy/saved and commits exactly once")
    }

    @MainActor func testCancelledCloseDrainsAdmittedSaveAndReleasesLock() async throws {
        let dir = root("cancelled-close"), app = try await open(dir)
        let title = String(repeating: "🧪", count: 60), responsible = String(repeating: "é", count: 80)
        try typeTask(app, title, responsible)
        try send(app, "task.save")
        let closing = Task { @MainActor in await app.close() }
        closing.cancel()
        await closing.value
        let saved = try disk(dir)
        XCTAssertEqual(saved.tasks.map(\.title), [title])
        XCTAssertEqual(saved.tasks.map(\.responsible), [responsible])
        XCTAssertEqual(saved.outbox.count, 2)
        let reopened = try await open(dir)
        XCTAssertEqual(reopened.presentation.workspace, saved)
        await reopened.close()
        print("PASS cancellation: cancelled closer drains admitted legal Unicode save, releases lock and permits exact fresh reopen")
    }
}
