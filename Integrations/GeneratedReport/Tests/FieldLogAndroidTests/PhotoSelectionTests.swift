import Foundation
import XCTest
import FieldLogModels
import FieldLogStorage
import MixerUI
import MixerAndroid
@testable import FieldLogAndroid

private let photoJPEG = Data([0xff, 0xd8, 0xff, 0xe0, 0, 2, 0xff, 0xd9])
private func photoDir(_ name: String) -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]!).appendingPathComponent("photo-" + name)
}
private enum PhotoFault: Error { case injected, precommit }
private final class PhotoFaultSwitch: @unchecked Sendable {
    let lock = NSLock()
    var stage = "", target = 0, seen = 0
    func arm(_ stage: String, _ target: Int) { lock.lock(); defer { lock.unlock() }; self.stage = stage; self.target = target; seen = 0 }
    func check(_ stage: String) throws {
        lock.lock(); defer { lock.unlock() }
        if stage == self.stage { seen += 1; if seen == target { throw PhotoFault.injected } }
    }
}
private actor PhotoDrainGate {
    var entered = false
    var release: CheckedContinuation<Void, Never>?
    var notification: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; notification?.resume(); notification = nil
        await withCheckedContinuation { release = $0 }
    }
    func arrival() async { if !entered { await withCheckedContinuation { notification = $0 } } }
    func open() { release?.resume(); release = nil }
}
final class PhotoSelectionTests: XCTestCase {
    @MainActor func testOriginalBatchSelectCurrentEditsSavePhotoReopenCommit() async throws {
        let dir = photoDir("roundtrip"), app = try await open(dir)
        try send(app, "workspace.entries")
        let before = try Data(contentsOf: file(dir)), note = "e\u{301}\n👩🏽‍🔬 exact\n"
        let batch = [try event(app, "entry.title", .textChange, .string("Photo entry")),
                     try event(app, "entry.note", .textChange, .string(note)),
                     try event(app, "entry.date.input", .textChange, .string("2024-02-29T01:00:00+01:00")),
                     try event(app, "entry.category.issue"), try event(app, "entry.photo.select")]
        var publications = 0
        let cancel = app.presentation.observe { _ in publications += 1 }
        try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode(batch))
        XCTAssertEqual(publications, 1); cancel()
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        let request = try XCTUnwrap(app.presentation.takePhotoRequest())
        XCTAssertNil(app.presentation.takePhotoRequest())
        XCTAssertEqual(request.draftID, app.presentation.entryState?.draft.id)
        try send(app, "entry.note", .textChange, .string(note + "later edit"))
        try send(app, "entry.saveDraft")
        let accepted = await app.presentation.completePhoto(requestID: request.id, result: .jpeg(photoJPEG))
        XCTAssertTrue(accepted)
        let saved = try XCTUnwrap(app.presentation.workspace.drafts.first)
        XCTAssertEqual(saved.note, note + "later edit"); XCTAssertEqual(saved.title, "Photo entry")
        XCTAssertEqual(saved.category, .issue); XCTAssertEqual(saved.occurredAt, Date(timeIntervalSince1970: 1709164800))
        XCTAssertEqual(saved.attachmentIDs.count, 1)
        let attachment = try XCTUnwrap(app.presentation.workspace.attachments.first)
        XCTAssertEqual(saved.attachmentIDs, [attachment.id])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("FieldLog/photos/" + attachment.filename)), photoJPEG)
        let duplicate = await app.presentation.completePhoto(requestID: request.id, result: .jpeg(photoJPEG))
        XCTAssertFalse(duplicate)
        await app.close()
        let reopened = try await open(dir)
        XCTAssertEqual(reopened.presentation.entryState?.draft, saved)
        try send(reopened, "entry.commit"); try await reopened.settle()
        XCTAssertEqual(reopened.presentation.workspace.entries.first?.attachmentIDs, [attachment.id])
        XCTAssertEqual(reopened.presentation.workspace.outbox.filter { $0.kind == .entrySaved }.count, 1)
        await reopened.close()
    }
    @MainActor func testSelectBatchRefusalHasNoPartialStateOrDiskEffect() async throws {
        let dir = photoDir("refusals"), app = try await open(dir)
        try send(app, "workspace.entries")
        let before = try Data(contentsOf: file(dir)), state = app.presentation.entryState, snapshot = app.presentation.snapshot
        let select = try event(app, "entry.photo.select"), title = try event(app, "entry.title", .textChange, .string("Must not leak"))
        let invalid = try event(app, "entry.date.input", .textChange, .string("2024-02-"))
        let nul = try event(app, "entry.note", .textChange, .string("bad\0note"))
        let oversized = try event(app, "entry.note", .textChange, .string(String(repeating: "a", count: 100001)))
        for batch in [[select, title], [title, select, select], [title, invalid, select], [nul, select], [oversized, select]] {
            try rejects("photo original batch refusal") { try app.sendBatch(owner: app.host.owner!, originalEnvelopes: JSONEncoder().encode(batch)) }
            XCTAssertEqual(app.presentation.entryState, state)
            XCTAssertEqual(app.presentation.snapshot.document, snapshot.document)
            XCTAssertNil(app.presentation.takePhotoRequest())
            XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        }
        await app.close()
    }
    @MainActor func testCancelledDeniedInvalidAndMalformedHaveNoPhotoEffect() async throws {
        let results: [PhotoSelectionResult] = [.cancelled, .failed(.denied), .failed(.invalid), .failed(.tooLarge), .failed(.unavailable), .jpeg(Data()), .jpeg(Data([1, 2, 3]))]
        for (index, result) in results.enumerated() {
            let dir = photoDir("zero-\(index)"), app = try await open(dir)
            try send(app, "workspace.entries"); try send(app, "entry.title", .textChange, .string("Keep title"))
            try send(app, "entry.note", .textChange, .string("Keep\nexact"))
            let draft = app.presentation.entryState?.draft, before = try Data(contentsOf: file(dir))
            try send(app, "entry.photo.select")
            let request = try XCTUnwrap(app.presentation.takePhotoRequest())
            let accepted = await app.presentation.completePhoto(requestID: request.id, result: result)
            XCTAssertEqual(accepted, index < 5)
            XCTAssertEqual(app.presentation.entryState?.draft, draft)
            XCTAssertEqual(try Data(contentsOf: file(dir)), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("FieldLog/photos").path))
            let duplicate = await app.presentation.completePhoto(requestID: request.id, result: .jpeg(photoJPEG))
            XCTAssertFalse(duplicate); await app.close()
        }
    }
    @MainActor func testLifetimeCancelAndInvalidRawDateFenceCallbacks() async throws {
        let dir = photoDir("fences"), app = try await open(dir)
        try send(app, "workspace.entries"); try send(app, "entry.photo.select")
        let old = try XCTUnwrap(app.presentation.takePhotoRequest())
        try send(app, "entry.new")
        let state = app.presentation.entryState
        let stale = await app.presentation.completePhoto(requestID: old.id, result: .jpeg(photoJPEG))
        XCTAssertFalse(stale); XCTAssertEqual(app.presentation.entryState, state)
        try send(app, "entry.photo.select")
        let cancelled = try XCTUnwrap(app.presentation.takePhotoRequest())
        try send(app, "entry.photo.cancel")
        let late = await app.presentation.completePhoto(requestID: cancelled.id, result: .jpeg(photoJPEG))
        XCTAssertFalse(late)
        try send(app, "entry.photo.select")
        let invalid = try XCTUnwrap(app.presentation.takePhotoRequest())
        try send(app, "entry.date.input", .textChange, .string("2024-02-"))
        let before = try Data(contentsOf: file(dir))
        let rejected = await app.presentation.completePhoto(requestID: invalid.id, result: .jpeg(photoJPEG))
        XCTAssertFalse(rejected); XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        try send(app, "entry.date.input", .textChange, .string("2024-02-29T00:00:00Z"))
        try send(app, "entry.photo.select")
        let closed = try XCTUnwrap(app.presentation.takePhotoRequest())
        await app.close()
        let afterClose = await app.presentation.completePhoto(requestID: closed.id, result: .jpeg(photoJPEG))
        XCTAssertFalse(afterClose); XCTAssertEqual(try Data(contentsOf: file(dir)), before)
    }
    @MainActor func testReservationExcludesNewSaveAcrossDrainSuspensionAndRetainsEarlierEdits() async throws {
        let dir = photoDir("reservation-barrier"), p = try await ProjectPresentation(directory: dir)
        func action(_ id: String, _ kind: UIEventKind = .activate, _ value: UIValue = .null) throws -> UIEventEnvelope {
            UIEventEnvelope(revision: p.snapshot.document.revision, identity: try XCTUnwrap(p.snapshot.identity(for: id)), event: kind, value: value)
        }
        try p.send(action("workspace.entries"))
        try p.send(action("entry.title", .textChange, .string("Retain before callback")))
        try p.send(action("entry.note", .textChange, .string("before reservation\nexact")))
        try p.send(action("entry.photo.select"))
        let request = try XCTUnwrap(p.takePhotoRequest()), save = try action("entry.saveDraft")
        let note = try action("entry.note", .textChange, .string("must not enter"))
        let before = try Data(contentsOf: file(dir)), gate = PhotoDrainGate()
        p.photoDrainBarrier = { await gate.hold() }
        let completion = Task { @MainActor in await p.completePhoto(requestID: request.id, result: .jpeg(photoJPEG)) }
        await gate.arrival()
        XCTAssertEqual(p.entryState?.saving, false)
        try rejects("save cannot enter callback drain window") { try p.send(save) }
        try rejects("edit cannot enter callback drain window") { try p.send(note) }
        XCTAssertEqual(try Data(contentsOf: file(dir)), before)
        await gate.open()
        let accepted = await completion.value; XCTAssertTrue(accepted)
        XCTAssertEqual(p.workspace.drafts.first?.note, "before reservation\nexact")
        XCTAssertEqual(p.workspace.drafts.first?.title, "Retain before callback")
        XCTAssertEqual(p.workspace.attachments.count, 1)
        // Reservation is released, so the next ordinary edit/save can proceed.
        try p.send(action("entry.title", .textChange, .string("After completion")))
        try p.send(action("entry.saveDraft")); try await p.waitForSave()
        XCTAssertEqual(p.workspace.drafts.first?.title, "After completion")
        await p.close()
    }
    func testRepositoryRealReferenceProjectionAndPrecommitBeforePhotoWrite() async throws {
        let dir = photoDir("precommit"), repository = try WorkspaceRepository(directory: dir)
        let initial = try await repository.transact { w in _ = try w.createProject(title: "Project", site: "") }
        let draft = EntryDraft(projectID: initial.projects[0].id, title: "Keep", note: "Latest\n")
        let before = try Data(contentsOf: dir.appendingPathComponent("workspace.json"))
        do {
            _ = try await repository.attachPhoto(jpeg: photoJPEG, to: draft, expectedRevision: initial.revision) { next in
                XCTAssertEqual(next.drafts.first?.attachmentIDs, next.attachments.map(\.id))
                XCTAssertEqual(next.drafts.first?.note, "Latest\n")
                XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos").path))
                throw PhotoFault.precommit
            }; XCTFail("precommit must reject")
        } catch PhotoFault.precommit { }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("workspace.json")), before)
        let saved = try await repository.attachPhoto(jpeg: photoJPEG, to: draft, expectedRevision: initial.revision) { _ in }
        XCTAssertEqual(saved.attachments.count, 1)
        let url = try await repository.photoURL(saved.attachments[0].id)
        XCTAssertEqual(try Data(contentsOf: url), photoJPEG)
        await repository.close()
    }
    func testRepositoryPhotoAndWorkspaceWriteFaultsRetainPrimaryErrorAndSafeReferences() async throws {
        for stage in ["before_write", "before_file_sync", "before_rename", "after_rename", "after_directory_sync"] {
            for target in 1...2 {
                let dir = photoDir("fault-\(stage)-\(target)"), injection = PhotoFaultSwitch()
                let repo = try WorkspaceRepository(directory: dir, fault: { try injection.check($0) })
                let initial = try await repo.transact { w in _ = try w.createProject(title: "Fault", site: "") }
                let draft = EntryDraft(projectID: initial.projects[0].id, title: "Safe")
                injection.arm(stage, target)
                do {
                    _ = try await repo.attachPhoto(jpeg: photoJPEG, to: draft, expectedRevision: initial.revision) { _ in }
                    XCTFail("injected IO must fail")
                } catch PhotoFault.injected { }
                let memory = await repo.snapshot(); XCTAssertEqual(memory, initial)
                do { _ = try await repo.transact { _ in }; XCTFail("uncertain IO must disable writes") } catch { }
                await repo.close()
                let reopened = try WorkspaceRepository(directory: dir), durable = await reopened.snapshot()
                let snapshotPublished = target == 2 && ["after_rename", "after_directory_sync"].contains(stage)
                XCTAssertEqual(durable.attachments.count, snapshotPublished ? 1 : 0)
                for attachment in durable.attachments {
                    let url = try await reopened.photoURL(attachment.id)
                    XCTAssertEqual(try Data(contentsOf: url), photoJPEG)
                }
                if target == 2 {
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("photos").path).count, 1, "retain orphan or committed photo after uncertain workspace write")
                }
                await reopened.close()
            }
        }
    }
    func testRepositoryBoundsStaleAndEightPhotoLimitHaveNoExtraEffect() async throws {
        let dir = photoDir("limits"), repo = try WorkspaceRepository(directory: dir)
        var current = try await repo.transact { w in _ = try w.createProject(title: "Limit", site: "") }
        var draft = EntryDraft(projectID: current.projects[0].id)
        for _ in 0..<8 {
            current = try await repo.attachPhoto(jpeg: photoJPEG, to: draft, expectedRevision: current.revision) { _ in }
            draft = try XCTUnwrap(current.drafts.first)
        }
        let before = try Data(contentsOf: dir.appendingPathComponent("workspace.json"))
        for (bytes, revision) in [(photoJPEG, current.revision), (photoJPEG, current.revision - 1), (Data(repeating: 0, count: 6_291_457), current.revision)] {
            do { _ = try await repo.attachPhoto(jpeg: bytes, to: draft, expectedRevision: revision) { _ in }; XCTFail("must reject") } catch { }
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("workspace.json")), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("photos").path).count, 8)
        await repo.close()
    }
}
