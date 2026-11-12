import Foundation
import XCTest
import FieldLogModels
import FieldLogFeatures
import FieldLogStorage
import MixerUI
import MixerAndroid
@testable import FieldLogAndroid

private func entryNodes(_ n: UINode) -> [UINode] { [n] + n.children.flatMap(entryNodes) }
@MainActor private func entryNode(_ app: PublicAndroidApplication, _ id: String) throws -> UINode {
    try XCTUnwrap(entryNodes(app.presentation.snapshot.document.root).first { $0.id == id })
}
private func entryDirectory(_ label: String) -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]!).appendingPathComponent("entry-" + label)
}
@MainActor private func typeEntry(_ app: PublicAndroidApplication, title: String, note: String) throws {
    try send(app, "entry.title", .textChange, .string(title))
    try send(app, "entry.note", .textChange, .string(note))
}

final class EntryPresentationTests: XCTestCase {
    @MainActor func testUnicodeDraftCloseFreshRestoreEditCommitAndEventRefusal() async throws {
        let dir = entryDirectory("roundtrip"), surface = R109Surface(), app = try await open(dir, surface)
        try typeTask(app, "Task draft stays 🧪", "Zoë")
        let taskState = app.presentation.state, initial = try Data(contentsOf: file(dir))
        try send(app, "workspace.entries")
        XCTAssertEqual(try Data(contentsOf: file(dir)), initial, "Opening an editor never autosaves")
        let note = "Café e\u{301} 👩🏽‍🔬\n東京\n\nLast line\n"
        try typeEntry(app, title: "Inspection 🧪", note: note)
        try send(app, "entry.category.issue")
        let draft = try XCTUnwrap(app.presentation.entryState).draft
        try send(app, "workspace.tasks")
        XCTAssertEqual(app.presentation.state, taskState)
        try send(app, "workspace.entries")
        XCTAssertEqual(app.presentation.entryState?.draft, draft)
        try send(app, "workspace.queue")
        XCTAssertTrue(try text(app).contains("Not sent"))
        try send(app, "workspace.entries")
        XCTAssertEqual(app.presentation.entryState?.draft, draft)
        let oldOwner = app.host.owner!, stale = try event(app, "entry.saveDraft")
        try send(app, "entry.saveDraft")
        XCTAssertTrue(app.presentation.entryState?.saving == true)
        let close = Task { @MainActor in await app.close() }; close.cancel(); await close.value
        let saved = try disk(dir)
        XCTAssertEqual(saved.drafts.count, 1)
        XCTAssertTrue(saved.drafts[0].note.utf8.elementsEqual(note.utf8))
        XCTAssertEqual(saved.drafts[0].occurredAt, draft.occurredAt)
        XCTAssertEqual(saved.drafts[0].category, .issue)
        XCTAssertEqual(saved.outbox.filter { $0.kind == .entrySaved }.count, 0)
        try rejects("closed owner") { try app.send(owner: oldOwner, originalEnvelope: JSONEncoder().encode(stale)) }
        let fresh = try await open(dir)
        XCTAssertNotNil(fresh.presentation.snapshot.identity(for: "entry.note"), "Restoration selects the durable draft")
        XCTAssertEqual(fresh.presentation.entryState?.draft.id, draft.id)
        XCTAssertTrue(try XCTUnwrap(fresh.presentation.entryState).draft.note.utf8.elementsEqual(note.utf8))
        try rejects("wrong owner") { try fresh.send(owner: oldOwner, originalEnvelope: JSONEncoder().encode(stale)) }
        try send(fresh, "entry.note", .textChange, .string(note + "Edited\n"))
        let commit = try event(fresh, "entry.commit")
        try send(fresh, "entry.commit"); try await fresh.settle()
        XCTAssertEqual(fresh.presentation.workspace.entries.count, 1)
        XCTAssertEqual(fresh.presentation.workspace.entries[0].id, draft.id)
        XCTAssertTrue(fresh.presentation.workspace.entries[0].note.utf8.elementsEqual((note + "Edited\n").utf8))
        XCTAssertTrue(fresh.presentation.workspace.drafts.isEmpty)
        XCTAssertEqual(fresh.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        let after = try Data(contentsOf: file(dir))
        try rejects("stale repeat commit") { try fresh.send(owner: fresh.host.owner!, originalEnvelope: JSONEncoder().encode(commit)) }
        try rejects("current disabled commit") { try send(fresh, "entry.commit") }
        XCTAssertEqual(try Data(contentsOf: file(dir)), after)
        await fresh.close()
        let final = try await open(dir)
        XCTAssertEqual(final.presentation.workspace.entries.count, 1)
        XCTAssertEqual(final.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        await final.close()
        print("PASS entry roundtrip: Unicode/LF exact draft disk restore; edit/commit once; canceled close drains; task draft/queue navigation; wrong/stale/closed/repeated commit refused")
    }

    @MainActor func testWholeOriginalBatchAtomicPublicationAndInvalidInputs() async throws {
        let dir = entryDirectory("batch"), app = try await open(dir)
        try send(app, "workspace.entries")
        let diskBefore = try Data(contentsOf: file(dir))
        let disabled = [try event(app, "entry.title", .textChange, .string("Ready")), try event(app, "entry.commit")]
        try rejects("disabled original commit cannot be rebased") { try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode(disabled)) }
        try typeEntry(app, title: "Ready", note: "Old")
        let captured = app.presentation.snapshot, before = app.presentation.entryState
        let title = try event(app, "entry.title", .textChange, .string("Updated"))
        let note = try event(app, "entry.note", .textChange, .string("e\u{301}\n🧪"))
        let commit = try event(app, "entry.commit"), queue = try event(app, "workspace.queue")
        var publications = 0
        let unsubscribe = app.presentation.observe { _ in publications += 1 }; defer { unsubscribe() }
        for events in [[title, commit, note], [title, queue], [queue, commit]] {
            try rejects("entire invalid entry batch") { try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode(events)) }
        }
        XCTAssertEqual(app.presentation.entryState, before)
        XCTAssertEqual(app.presentation.snapshot.document, captured.document)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: file(dir)), diskBefore)
        try rejects("wrong event kind") { try send(app, "entry.note", .activate, .null) }
        try rejects("wrong value") { try send(app, "entry.note", .textChange, .bool(true)) }
        try rejects("V4 oversized field") { try send(app, "entry.note", .textChange, .string(String(repeating: "é", count: 50_001))) }
        XCTAssertEqual(app.presentation.entryState, before)
        XCTAssertEqual(try Data(contentsOf: file(dir)), diskBefore)
        try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode([title, note, commit]))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(app.presentation.snapshot.document.revision, captured.document.revision + 1)
        XCTAssertEqual(try Data(contentsOf: file(dir)), diskBefore)
        try await app.settle()
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(app.presentation.workspace.entries.map(\.title), ["Updated"])
        XCTAssertEqual(app.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        await app.close()
        print("PASS entry batch: original-envelope grammar; no partial reducer/disk/frame; one admission and one completion publication; V4 oversize refused before mutation")
    }

    @MainActor func testExplicitExistingDraftSelectionPreservesDateCategoryAttachmentsAndTasks() async throws {
        let dir = entryDirectory("select"), repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
        let date = Date(timeIntervalSinceReferenceDate: 123456.875)
        let seed = try await repo.transact { w in
            let p = try w.createProject(title: "Site", site: "")
            try w.saveTask(projectID: p, title: "Existing task", responsible: "Jo")
            try w.saveDraft(EntryDraft(projectID: p, title: "First", note: "Exact\nfirst", category: .delivery, occurredAt: date))
            try w.saveDraft(EntryDraft(projectID: p, title: "Second", note: "Second note", category: .progress))
        }
        let firstID = seed.drafts[0].id
        let withPhoto = try await repo.addPhoto(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), to: firstID)
        await repo.close()
        let app = try await open(dir), before = try Data(contentsOf: file(dir))
        try typeTask(app, "Keep this active task", "Lee")
        let taskState = app.presentation.state
        try send(app, "workspace.entries")
        try send(app, "draft." + firstID.uuidString.lowercased())
        let selected = try XCTUnwrap(app.presentation.entryState).draft
        XCTAssertEqual(selected, withPhoto.drafts[0])
        XCTAssertTrue(try entryNode(app, "entry.occurredAt").properties["text"]!.string!.contains("875"))
        XCTAssertTrue(try entryNode(app, "entry.date.help").properties["text"]!.string!.contains("not available"))
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        try send(app, "entry.title", .textChange, .string("First edited"))
        try send(app, "entry.commit"); try await app.settle()
        let committed = try XCTUnwrap(app.presentation.workspace.entries.first)
        XCTAssertEqual(committed.attachmentIDs, selected.attachmentIDs)
        XCTAssertEqual(committed.occurredAt, date)
        XCTAssertEqual(committed.category, .delivery)
        XCTAssertEqual(app.presentation.workspace.attachments, withPhoto.attachments)
        XCTAssertEqual(app.presentation.workspace.tasks, withPhoto.tasks)
        XCTAssertEqual(Array(app.presentation.workspace.outbox.prefix(withPhoto.outbox.count)), withPhoto.outbox)
        try send(app, "workspace.tasks")
        XCTAssertEqual(app.presentation.state, taskState)
        await app.close()
        XCTAssertEqual(try disk(dir).entries[0], committed)
        print("PASS selected draft: explicit identity; full date/category/note/attachments; unchanged task records/outbox and active task draft")
    }

    @MainActor func testEntryAndDraftTwentyRecordPaginationNoWrites() async throws {
        let dir = entryDirectory("pages"), repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
        let saved = try await repo.transact { w in
            let p = try w.createProject(title: "Pages", site: "")
            for i in 0..<43 {
                let d = EntryDraft(projectID: p, title: "Entry \(i)", note: "🧪\n\(i)", occurredAt: Date(timeIntervalSinceReferenceDate: Double(i)))
                try w.saveDraft(d); try w.commitDraft(d.id)
            }
            for i in 0..<23 { try w.saveDraft(EntryDraft(projectID: p, title: "Draft \(i)")) }
        }
        await repo.close()
        let app = try await open(dir), before = try Data(contentsOf: file(dir))
        try send(app, "workspace.entries")
        var seen: [UUID] = []
        for page in 0..<3 {
            let ids = saved.entries(for: saved.projects[0].id).filter { app.presentation.snapshot.identity(for: "entry." + $0.id.uuidString.lowercased()) != nil }.map(\.id)
            XCTAssertEqual(ids.count, page < 2 ? 20 : 3); seen += ids
            if page < 2 { try send(app, "entries.next") }
        }
        XCTAssertEqual(seen, saved.entries(for: saved.projects[0].id).map(\.id))
        try rejects("last entries page") { try send(app, "entries.next") }
        XCTAssertEqual(saved.drafts.filter { app.presentation.snapshot.identity(for: "draft." + $0.id.uuidString.lowercased()) != nil }.count, 20)
        try send(app, "drafts.next")
        XCTAssertEqual(saved.drafts.filter { app.presentation.snapshot.identity(for: "draft." + $0.id.uuidString.lowercased()) != nil }.count, 3)
        try rejects("last drafts page") { try send(app, "drafts.next") }
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        await app.close()
        print("PASS entry pagination: 43 entries on 20/20/3 pages, 23 selectable drafts on 20/3; navigation leaves disk exact")
    }

    @MainActor func testActualPostMutationLongNoteProjectionRefusesBeforeDurableWrite() async throws {
        let dir = entryDirectory("preflight"), app = try await open(dir)
        try send(app, "workspace.entries")
        let project = app.presentation.workspace.projects[0].id
        var reconciler = UIReconciler(validator: UIValidator(supportedTextFieldAxes: AndroidUIProfile.measuredMultilineRetirementV3.capabilities.textFieldAxes))
        try reconciler.apply(app.presentation.snapshot.document)
        let captured = reconciler, task = app.presentation.state
        let before = try Data(contentsOf: file(dir))
        await app.close()
        let repo = try WorkspaceRepository(directory: dir.appendingPathComponent("FieldLog"))
        let draft = EntryDraft(projectID: project, title: "Valid model", note: String(repeating: "é", count: 50_000))
        let intent = EntrySaveIntent(projectID: project, draft: draft, kind: .commit)
        try intent.validate() // Exactly 100,000 UTF-8 bytes remains a valid model.
        let state = EntryEditorState(draft: draft)
        do {
            _ = try await repo.transact { w in
                try intent.apply(to: &w)
                try ProjectPresentation.preflightEntry(w, state: state, task: task, project: project,
                    taskPage: 0, queuePage: 0, entryPage: 0, draftPage: 0, reconciler: captured)
            }
            XCTFail("V3 must reject long model projection before persistence")
        } catch UIValidationError.limitExceeded("stringBytes") { }
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        let unchanged = await repo.snapshot()
        XCTAssertTrue(unchanged.entries.isEmpty)
        await repo.close()
        print("PASS entry precommit: actual intent generated entry/outbox in transaction; valid 100000-byte model refused by V3 frame before file/revision mutation")
    }

    @MainActor func testBlankDraftAndNULValidationPreserveDiskAndInput() async throws {
        let dir = entryDirectory("invalid"), app = try await open(dir)
        try send(app, "workspace.entries")
        try rejects("blank commit") { try send(app, "entry.commit") }
        try send(app, "entry.saveDraft"); try await app.settle()
        XCTAssertEqual(app.presentation.workspace.drafts.count, 1)
        XCTAssertTrue(app.presentation.workspace.entries.isEmpty)
        let before = try Data(contentsOf: file(dir))
        try send(app, "entry.note", .textChange, .string("unsafe\u{0}note"))
        try send(app, "entry.saveDraft"); try await app.settle()
        XCTAssertNotNil(app.presentation.entryState?.failure)
        XCTAssertEqual(app.presentation.entryState?.draft.note, "unsafe\u{0}note")
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        try typeEntry(app, title: "Retry", note: "Valid\nexact")
        try send(app, "entry.commit"); try await app.settle()
        XCTAssertEqual(app.presentation.workspace.entries.count, 1)
        XCTAssertEqual(app.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        await app.close()
        print("PASS entry validation: blank draft saves without entry effect; blank commit disabled; NUL failure keeps input/disk; exact corrected retry commits once")
    }
}
