import Foundation
import XCTest
import FieldLogModels
import FieldLogStorage
import MixerUI
import MixerAndroid
@testable import FieldLogAndroid

private func dateNodes(_ n: UINode) -> [UINode] { [n] + n.children.flatMap(dateNodes) }
@MainActor private func dateNode(_ app: PublicAndroidApplication, _ id: String) throws -> UINode {
    try XCTUnwrap(dateNodes(app.presentation.snapshot.document.root).first { $0.id == id })
}
@MainActor private func dateValue(_ app: PublicAndroidApplication) throws -> String {
    try XCTUnwrap(dateNode(app, "entry.date.input").properties["value"]?.string)
}
private func dateDirectory(_ label: String) -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]!).appendingPathComponent("date-" + label)
}
@MainActor private func typeDate(_ app: PublicAndroidApplication, _ text: String) throws {
    try send(app, "entry.date.input", .textChange, .string(text))
}

final class EntryDatePresentationTests: XCTestCase {
    @MainActor func testOffsetLeapDateSaveReopenCommitAndExactlyOneOutboxEffect() async throws {
        let dir = dateDirectory("roundtrip"), app = try await open(dir)
        try send(app, "workspace.entries")
        let note = "e\u{301}\n👩🏽‍🔬 exact\n"
        try send(app, "entry.title", .textChange, .string("Leap day"))
        try send(app, "entry.note", .textChange, .string(note))
        let before = try Data(contentsOf: file(dir))
        let raw = "2024-02-29T23:45:12.125+05:30"
        try typeDate(app, raw)
        let expected = Date(timeIntervalSince1970: 1709230512.125)
        XCTAssertEqual(app.presentation.entryState?.draft.occurredAt, expected)
        XCTAssertEqual(try dateValue(app), raw)
        try send(app, "entry.category.issue")
        XCTAssertEqual(try dateValue(app), raw)
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        try send(app, "entry.saveDraft"); try await app.settle()
        XCTAssertEqual(app.presentation.workspace.drafts.first?.occurredAt, expected)
        XCTAssertEqual(app.presentation.workspace.drafts.first?.category, .issue)
        XCTAssertEqual(app.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 0)
        await app.close()
        let restored = try await open(dir)
        XCTAssertEqual(restored.presentation.entryState?.draft.occurredAt, expected)
        XCTAssertEqual(restored.presentation.entryState?.draft.category, .issue)
        XCTAssertTrue(try XCTUnwrap(restored.presentation.entryState).draft.note.utf8.elementsEqual(note.utf8))
        let commit = try event(restored, "entry.commit")
        try send(restored, "entry.commit"); try await restored.settle()
        XCTAssertEqual(restored.presentation.workspace.entries.first?.occurredAt, expected)
        XCTAssertEqual(restored.presentation.workspace.entries.first?.category, .issue)
        XCTAssertEqual(restored.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        let finalBytes = try Data(contentsOf: file(dir))
        try rejects("stale date entry commit") { try restored.send(owner: restored.host.owner!, originalEnvelope: JSONEncoder().encode(commit)) }
        try rejects("committed date disabled") { try typeDate(restored, "2025-01-01T00:00:00Z") }
        XCTAssertEqual(try Data(contentsOf: file(dir)), finalBytes)
        await restored.close()
    }

    @MainActor func testUntouchedSubmillisecondDateAndEchoRemainExact() async throws {
        let dir = dateDirectory("untouched"), repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
        let original = Date(timeIntervalSinceReferenceDate: 123456.123456789)
        _ = try await repo.transact { w in
            let project = try w.createProject(title: "Date", site: "")
            try w.saveDraft(EntryDraft(projectID: project, title: "Exact", note: " unchanged\n", category: .delivery, occurredAt: original))
        }
        await repo.close()
        let app = try await open(dir)
        try send(app, "workspace.entries")
        let id = try XCTUnwrap(app.presentation.workspace.drafts.first).id
        try send(app, "draft." + id.uuidString.lowercased())
        // Native control may echo its initial display without a semantic edit.
        try typeDate(app, try dateValue(app))
        try send(app, "entry.category.issue")
        try send(app, "entry.saveDraft"); try await app.settle()
        XCTAssertEqual(app.presentation.workspace.drafts.first?.occurredAt, original)
        await app.close()
        let restored = try await open(dir)
        try send(restored, "entry.commit"); try await restored.settle()
        XCTAssertEqual(restored.presentation.workspace.entries.first?.occurredAt, original)
        XCTAssertEqual(restored.presentation.workspace.entries.first?.note, " unchanged\n")
        await restored.close()
    }

    @MainActor func testInvalidPartialInputRetainedNavigationAndWholeBatchRefusal() async throws {
        let dir = dateDirectory("invalid"), app = try await open(dir)
        try send(app, "workspace.entries")
        try send(app, "entry.title", .textChange, .string("Valid title"))
        try typeDate(app, "2024-02-29T00:00:00Z")
        let valid = try XCTUnwrap(app.presentation.entryState).draft.occurredAt
        let raw = "2024-02-"
        try typeDate(app, raw)
        let prior = app.presentation.entryState, snapshot = app.presentation.snapshot
        let before = try Data(contentsOf: file(dir))
        XCTAssertEqual(try dateValue(app), raw)
        XCTAssertEqual(app.presentation.entryState?.draft.occurredAt, valid)
        XCTAssertNotNil(try dateNode(app, "entry.date.error"))
        for save in ["entry.saveDraft", "entry.commit"] {
            try rejects("invalid date save disabled") { try send(app, save) }
        }
        XCTAssertEqual(app.presentation.entryState, prior)
        XCTAssertEqual(app.presentation.snapshot.document, snapshot.document)
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        try send(app, "workspace.tasks"); try send(app, "workspace.entries")
        XCTAssertEqual(try dateValue(app), raw)
        try send(app, "workspace.queue"); try send(app, "workspace.entries")
        XCTAssertEqual(try dateValue(app), raw)
        try typeDate(app, "2024-02-29T00:00:00Z")
        let captured = app.presentation.snapshot, state = app.presentation.entryState
        let title = try event(app, "entry.title", .textChange, .string("Must not leak"))
        let invalid = try event(app, "entry.date.input", .textChange, .string("2023-02-29T00:00:00Z"))
        let save = try event(app, "entry.saveDraft")
        try rejects("invalid date plus save is atomic") { try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode([title, invalid, save])) }
        XCTAssertEqual(app.presentation.entryState, state)
        XCTAssertEqual(app.presentation.snapshot.document, captured.document)
        XCTAssertEqual(try dateValue(app), "2024-02-29T00:00:00Z")
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        XCTAssertEqual(app.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 0)
        // A stale event from the previous draft must not edit the new draft.
        let stale = try event(app, "entry.date.input", .textChange, .string("2026-01-01T00:00:00Z"))
        try send(app, "entry.new")
        let newDate = app.presentation.entryState?.draft.occurredAt
        try rejects("crossdraft date") { try app.send(owner: app.host.owner!, originalEnvelope: JSONEncoder().encode(stale)) }
        XCTAssertEqual(app.presentation.entryState?.draft.occurredAt, newDate)
        XCTAssertNotEqual(try dateValue(app), raw)
        await app.close()
    }

    @MainActor func testStrictFiniteRFC3339SubsetAndDefaultPolicyRefusals() async throws {
        let dir = dateDirectory("subset"), app = try await open(dir)
        try send(app, "workspace.entries")
        let original = app.presentation.entryState?.draft.occurredAt
        let before = try Data(contentsOf: file(dir))
        let rejected = ["2023-02-29T00:00:00Z", "1900-02-29T00:00:00Z", "2024-04-31T00:00:00Z", "2024-01-01T24:00:00Z", "2024-01-01T00:00:60Z", "2024-01-01T00:00:00+24:00", "2024-01-01T00:00:00+05:60", "2024-01-01T00:00:00-00:00", "2024-01-01T00:00:00.1234Z", "2024-01-01T00:00:00.Z", "2024-01-01T00:00:00", "0000-01-01T00:00:00Z", "2024-01-01t00:00:00z", " 2024-01-01T00:00:00Z"]
        for raw in rejected {
            try typeDate(app, raw)
            XCTAssertEqual(try dateValue(app), raw)
            XCTAssertEqual(app.presentation.entryState?.draft.occurredAt, original, raw)
            XCTAssertNotNil(try dateNode(app, "entry.date.error"))
        }
        let captured = app.presentation.snapshot
        try rejects("date NUL") { try typeDate(app, "2024-01-01T00:00:00Z\0") }
        try rejects("date standard oversize") { try typeDate(app, String(repeating: "a", count: UIValidationLimits.standard.maximumStringBytes + 1)) }
        XCTAssertEqual(app.presentation.snapshot.document, captured.document)
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        let accepted: [(String, Double)] = [
            ("1970-01-01T00:00:00Z", 0),
            ("1970-01-01T01:00:00+01:00", 0),
            ("1969-12-31T19:00:00-05:00", 0),
            ("1970-01-01T00:00:00.1Z", 0.1),
            ("1970-01-01T00:00:00.12Z", 0.12),
            ("2000-02-29T00:00:00Z", 951782400),
            ("0001-01-01T00:00:00Z", -62135596800),
            ("9999-12-31T23:59:59Z", 253402300799)
        ]
        for (raw, seconds) in accepted {
            try typeDate(app, raw)
            XCTAssertEqual(try XCTUnwrap(app.presentation.entryState).draft.occurredAt.timeIntervalSince1970, seconds, accuracy: 0.000001, raw)
            XCTAssertEqual(try dateValue(app), raw)
        }
        await app.close()
    }
    @MainActor func testBatchedDateCategorySaveStorageFailureRetainsExactRetry() async throws {
        let dir = dateDirectory("storage-retry"), app = try await open(dir)
        try send(app, "workspace.entries")
        try send(app, "entry.title", .textChange, .string("Retry exact"))
        let raw = "2000-02-29T01:00:00.125+01:00"
        let expected = Date(timeIntervalSince1970: 951782400.125)
        let originalFile = file(dir), backup = originalFile.appendingPathExtension("r780-backup")
        let before = try Data(contentsOf: originalFile), beforeWorkspace = app.presentation.workspace
        // A transient read failure happens before any durable mutation. Restore the
        // exact original file to prove the presentation can retry the same input.
        try FileManager.default.moveItem(at: originalFile, to: backup)
        try FileManager.default.createDirectory(at: originalFile, withIntermediateDirectories: false)
        let batch = [try event(app, "entry.date.input", .textChange, .string(raw)),
                     try event(app, "entry.category.delivery"), try event(app, "entry.saveDraft")]
        try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode(batch))
        try await app.settle()
        XCTAssertNotNil(app.presentation.entryState?.failure)
        XCTAssertEqual(try dateValue(app), raw)
        XCTAssertEqual(app.presentation.entryState?.draft.occurredAt, expected)
        XCTAssertEqual(app.presentation.entryState?.draft.category, .delivery)
        XCTAssertEqual(app.presentation.workspace, beforeWorkspace)
        XCTAssertEqual(try Data(contentsOf: backup), before)
        try FileManager.default.removeItem(at: originalFile)
        try FileManager.default.moveItem(at: backup, to: originalFile)
        try send(app, "entry.saveDraft"); try await app.settle()
        XCTAssertNil(app.presentation.entryState?.failure)
        XCTAssertEqual(app.presentation.workspace.drafts.first?.occurredAt, expected)
        XCTAssertEqual(try dateValue(app), raw)
        let edited = "2000-03-01T01:00:00.125+01:00"
        let commit = [try event(app, "entry.date.input", .textChange, .string(edited)),
                      try event(app, "entry.category.issue"), try event(app, "entry.commit")]
        try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode(commit))
        try await app.settle()
        XCTAssertEqual(app.presentation.workspace.entries.first?.occurredAt, Date(timeIntervalSince1970: 951868800.125))
        XCTAssertEqual(app.presentation.workspace.entries.first?.category, .issue)
        XCTAssertEqual(app.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        await app.close()
    }

}
