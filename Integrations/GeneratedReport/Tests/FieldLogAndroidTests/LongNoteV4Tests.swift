import Foundation
import XCTest
import FieldLogModels
import FieldLogStorage
import MixerUI
import MixerAndroid
@testable import FieldLogAndroid

final class LongNoteV4Tests: XCTestCase {
    @MainActor func testExact100000ByteOriginalBatchSaveReopenCommitAndRefusals() async throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]))
        let dir = root.appendingPathComponent("long-note-v4")
        let app = try await open(dir)
        try send(app, "workspace.entries")
        try send(app, "entry.title", .textChange, .string("Long note 🧪"))
        let note = String(repeating: "é\n", count: 33_333) + "X"
        XCTAssertEqual(note.utf8.count, 100_000)
        let original = try JSONEncoder().encode([event(app, "entry.note", .textChange, .string(note)), event(app, "entry.saveDraft")])
        XCTAssertGreaterThan(original.count, 131_072)
        XCTAssertLessThan(original.count, AndroidUIProfile.measuredMultilineLongNotesV4.maximumEventBytes)
        let before = try Data(contentsOf: file(dir))
        let state = app.presentation.entryState, snapshot = app.presentation.snapshot.document
        for (id, value) in [("entry.note", note + "X"), ("entry.title", String(repeating: "é", count: 8193)), ("entry.title", "unsafe\u{0}title")] {
            try rejects("V4 field refusal " + id) { try send(app, id, .textChange, .string(value)) }
            XCTAssertEqual(app.presentation.entryState, state)
            XCTAssertEqual(app.presentation.snapshot.document, snapshot)
            XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        }
        try app.sendBatch(owner: app.host.owner!, originalEnvelopes: original)
        try await app.settle()
        let draft = try XCTUnwrap(app.presentation.workspace.drafts.first)
        XCTAssertEqual(Array(draft.note.utf8), Array(note.utf8))
        XCTAssertEqual(app.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 0)
        let tasks = app.presentation.workspace.tasks, priorOutbox = app.presentation.workspace.outbox
        await app.close()
        let fresh = try await open(dir)
        XCTAssertEqual(Array(try XCTUnwrap(fresh.presentation.entryState).draft.note.utf8), Array(note.utf8))
        XCTAssertEqual(fresh.presentation.entryState?.draft.id, draft.id)
        try send(fresh, "entry.commit"); try await fresh.settle()
        XCTAssertEqual(Array(try XCTUnwrap(fresh.presentation.workspace.entries.first).note.utf8), Array(note.utf8))
        XCTAssertTrue(fresh.presentation.workspace.drafts.isEmpty)
        XCTAssertEqual(fresh.presentation.workspace.tasks, tasks)
        XCTAssertEqual(Array(fresh.presentation.workspace.outbox.prefix(priorOutbox.count)), priorOutbox)
        XCTAssertEqual(fresh.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        await fresh.close()
        let final = try await open(dir)
        XCTAssertEqual(Array(try XCTUnwrap(final.presentation.workspace.entries.first).note.utf8), Array(note.utf8))
        XCTAssertEqual(final.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        await final.close()
    }

    @MainActor func testV3AdmissionAndDefaultFieldsRemainRefused() async throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]))
        let dir = root.appendingPathComponent("long-note-v3-refusal")
        let surface = V3CounterexampleSurface()
        do {
            _ = try await PublicAndroidApplication(surface: surface, selectedProfile: surface.profile.rawValue, directory: dir)
            XCTFail("V3 cannot silently open the explicit V4 app")
        } catch PublicHostError.profile { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir).path))
        let app = try await open(dir)
        let before = try Data(contentsOf: file(dir)), state = app.presentation.state
        for id in ["task.title", "task.responsible"] {
            for value in [String(repeating: "x", count: 16_385), "unsafe\u{0}field"] {
                try rejects("standard field " + id) { try send(app, id, .textChange, .string(value)) }
                XCTAssertEqual(app.presentation.state, state)
                XCTAssertEqual(try Data(contentsOf: file(dir)), before)
            }
        }
        try send(app, "workspace.entries")
        var legacy = UIReconciler(validator: UIValidator(supportedTextFieldAxes: AndroidUIProfile.measuredMultilineRetirementV3.capabilities.textFieldAxes))
        try legacy.apply(app.presentation.snapshot.document)
        let oldEnvelope = try event(app, "entry.note", .textChange, .string(String(repeating: "é", count: 8193)))
        XCTAssertThrowsError(try legacy.currentSnapshot().route(oldEnvelope), "Original V3 oversized-field refusal remains")
        await app.close()
    }
}

@MainActor private final class V3CounterexampleSurface: AndroidUINativeSurface {
    let profile = AndroidUIProfile.measuredMultilineRetirementV3
    var capabilities: AndroidUICapabilities { profile.capabilities }
    func activate(owner: UUID) throws { XCTFail("V3 must fail before activation") }
    func install(_ frame: AndroidUIFrame) throws { XCTFail("V3 must fail before installation") }
    func revoke(owner: UUID) { }
}
