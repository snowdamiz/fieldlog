import Foundation
import XCTest
import FieldLogModels
import FieldLogStorage
import MixerUI
import MixerAndroid
@testable import FieldLogAndroid

private struct Packet {
    static func decode(_ data: Data) throws -> Packet {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let document = try UIDocument.decode(JSONSerialization.data(withJSONObject: XCTUnwrap(object["document"])), validator: UIValidator(supportedTextFieldAxes: AndroidUIProfile.measuredMultilineLongNotesV4.capabilities.textFieldAxes, textValuePolicy: AndroidUIProfile.measuredMultilineLongNotesV4.textValuePolicy))
        let identities = try JSONDecoder().decode([UINodeIdentity].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["identities"])))
        return Packet(document: document, identities: identities)
    }
    let document: UIDocument
    let identities: [UINodeIdentity]
    func event(_ id: String, _ kind: UIEventKind, _ value: UIValue = .null) throws -> UIEventEnvelope {
        UIEventEnvelope(revision: document.revision, identity: try XCTUnwrap(identities.first { $0.id == id }), event: kind, value: value)
    }
}
@MainActor private enum Captures {
    struct Frame { let owner: Data; let packet: Data }
    static var owners: [Int64: Data] = [:]
    static var frames: [Int64: [Frame]] = [:]
    static var revocations: [Int64: Int] = [:]
    static func receive(_ context: Int64, _ operation: Int32, _ owner: Data, _ packet: Data, _ appearance: Data) -> Int32 {
        guard Thread.isMainThread else { return 1 }
        switch operation {
        case 0:
            guard owners[context] == nil else { return 1 }
            owners[context] = owner
        case 1:
            guard owners[context] == owner, (try? Packet.decode(packet)) != nil,
                  appearance == (try? UIAppearanceDescriptorCodecV2.canonicalData(UIAppearanceDescriptorCodecV2.mixerDefaultV2())) else { return 1 }
            frames[context, default: []].append(Frame(owner: owner, packet: packet))
        case 2:
            guard owners[context] == owner else { return 1 }
            owners.removeValue(forKey: context); revocations[context, default: 0] += 1
        default: return 1
        }
        return 0
    }
}
private let callback: @convention(c) @Sendable (Int64, Int32, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int) -> Int32 = { context, operation, owner, ownerCount, packet, packetCount, appearance, appearanceCount in
    let o = owner.map { Data(bytes: $0, count: ownerCount) } ?? Data()
    let p = packet.map { Data(bytes: $0, count: packetCount) } ?? Data()
    let a = appearance.map { Data(bytes: $0, count: appearanceCount) } ?? Data()
    return MainActor.assumeIsolated { Captures.receive(context, operation, o, p, a) }
}

@MainActor private func request(_ context: Int64, _ operation: Int32, directory: URL? = nil, owner: Data = Data(), event: Data = Data()) throws -> Int32 {
    XCTAssertTrue(Thread.isMainThread, "C-entry poll requires the real main thread")
    let profile = Data((operation == 0 ? AndroidUIProfile.measuredMultilineLongNotesV4.rawValue : "").utf8)
    let directory = Data((directory?.path ?? "").utf8)
    let accepted = profile.withUnsafeBytes { p in directory.withUnsafeBytes { d in owner.withUnsafeBytes { o in event.withUnsafeBytes { e in
        publicAndroidSubmit(context, operation, p.bindMemory(to: UInt8.self).baseAddress, p.count,
            d.bindMemory(to: UInt8.self).baseAddress, d.count,
            o.bindMemory(to: UInt8.self).baseAddress, o.count,
            e.bindMemory(to: UInt8.self).baseAddress, e.count, callback)
    } } } }
    guard accepted == 0 else { return -10 }
    let deadline = Date(timeIntervalSinceNow: 10)
    while Date() < deadline {
        let result = publicAndroidPoll(context)
        if result != 0 { return result }
    }
    XCTFail("C-entry timeout: retained context \(context)")
    throw PublicHostError.context
}

@MainActor private final class Surface: AndroidUINativeSurface {
    let profile = AndroidUIProfile.measuredMultilineLongNotesV4
    var capabilities: AndroidUICapabilities { profile.capabilities }
    var owner: UUID?
    var frames: [AndroidUIFrame] = []
    func activate(owner: UUID) throws { XCTAssertNil(self.owner); self.owner = owner }
    func install(_ frame: AndroidUIFrame) throws { XCTAssertEqual(owner, frame.owner); frames.append(frame) }
    func revoke(owner: UUID) { XCTAssertEqual(self.owner, owner); self.owner = nil }
}

final class FieldLogGeneratedHostTests: XCTestCase {
    @MainActor func testV4DirectoryABIOriginalLongNoteSaveFreshReopenCommit() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]))
        let dir = root.appendingPathComponent("centry-v4-long-note")
        XCTAssertEqual(try request(401, 0, directory: dir), 1)
        var frame = try XCTUnwrap(Captures.frames[401]?.last)
        var packet = try Packet.decode(frame.packet)
        XCTAssertEqual(try request(401, 1, owner: frame.owner, event: JSONEncoder().encode(packet.event("workspace.entries", .activate))), 1)
        frame = try XCTUnwrap(Captures.frames[401]?.last); packet = try Packet.decode(frame.packet)
        XCTAssertEqual(try request(401, 1, owner: frame.owner, event: JSONEncoder().encode(packet.event("entry.title", .textChange, .string("C-entry V4")))), 1)
        frame = try XCTUnwrap(Captures.frames[401]?.last); packet = try Packet.decode(frame.packet)
        let note = String(repeating: "é\n", count: 33_333) + "X"
        XCTAssertEqual(note.utf8.count, 100_000)
        let batch = try JSONEncoder().encode([packet.event("entry.note", .textChange, .string(note)), packet.event("entry.saveDraft", .activate)])
        XCTAssertGreaterThan(batch.count, 131_072)
        XCTAssertEqual(try request(401, 1, owner: frame.owner, event: batch), 1)
        XCTAssertEqual(Array(try disk(dir).drafts[0].note.utf8), Array(note.utf8))
        XCTAssertEqual(try request(401, 2), 1)
        XCTAssertEqual(try request(402, 0, directory: dir), 1)
        frame = try XCTUnwrap(Captures.frames[402]?.last); packet = try Packet.decode(frame.packet)
        XCTAssertEqual(try request(402, 1, owner: frame.owner, event: JSONEncoder().encode(packet.event("entry.commit", .activate))), 1)
        XCTAssertEqual(Array(try disk(dir).entries[0].note.utf8), Array(note.utf8))
        XCTAssertEqual(try disk(dir).outbox.filter { $0.kind == .entrySaved }.count, 1)
        XCTAssertEqual(try request(402, 2), 1)
    }

    @MainActor func testCEntryActualUnicodeSaveCloseFreshReopenAndContextIsolation() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"]), isDirectory: true)
        let a = root.appendingPathComponent("centry-a"), b = root.appendingPathComponent("centry-b")
        XCTAssertEqual(try request(101, 0, directory: a), 1)
        XCTAssertEqual(try request(102, 0, directory: b), 1)
        let initial = try XCTUnwrap(Captures.frames[101]?.last)
        var packet = try Packet.decode(initial.packet)
        let file = a.appendingPathComponent("FieldLog/workspace.json")
        let initialDisk = try Data(contentsOf: file)
        // Save is disabled in the originating empty frame. A prior text event
        // cannot rebase it into an enabled Save within that same captured frame.
        let disabled = try JSONEncoder().encode([packet.event("task.title", .textChange, .string("seed")), packet.event("task.save", .activate)])
        XCTAssertEqual(try request(101, 1, owner: initial.owner, event: disabled), 2)
        XCTAssertEqual(try Data(contentsOf: file), initialDisk)
        XCTAssertEqual(Captures.frames[101]?.count, 1)
        let seed = try JSONEncoder().encode(packet.event("task.title", .textChange, .string("ready")))
        XCTAssertEqual(try request(101, 1, owner: initial.owner, event: seed), 1)
        packet = try Packet.decode(XCTUnwrap(Captures.frames[101]?.last).packet)
        let title = "Café 東京 🧪\nInspect façade — e\u{301}"
        let responsible = "Zoë 👩🏽‍🔬 / Łukasz"
        let first = try packet.event("task.title", .textChange, .string(title))
        let person = try packet.event("task.responsible", .textChange, .string(responsible))
        let save = try packet.event("task.save", .activate)
        let invalidTail = try packet.event("task.title", .textChange, .string("after Save"))
        let beforeInvalid = Captures.frames[101]?.count
        XCTAssertEqual(try request(101, 1, owner: initial.owner, event: JSONEncoder().encode([first, person, save, invalidTail])), 2)
        XCTAssertEqual(Captures.frames[101]?.count, beforeInvalid)
        XCTAssertEqual(try Data(contentsOf: file), initialDisk)
        let burst = try JSONEncoder().encode([first, person, save])
        XCTAssertEqual(try request(101, 1, owner: initial.owner, event: burst), 1)
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.tasks.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(saved.tasks.first).title.utf8), Array(title.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(saved.tasks.first).responsible.utf8), Array(responsible.utf8))
        XCTAssertEqual(saved.outbox.filter { $0.kind == .taskSaved }.count, 1)
        XCTAssertEqual(try request(101, 2), 1)
        XCTAssertEqual(Captures.revocations[101], 1)
        XCTAssertEqual(try request(103, 0, directory: a), 1)
        let reopened = try XCTUnwrap(Captures.frames[103]?.last)
        XCTAssertNotEqual(reopened.owner, initial.owner)
        XCTAssertTrue(String(decoding: reopened.packet, as: UTF8.self).contains(title.replacingOccurrences(of: "\n", with: "\\u000a")))
        // A late original owner/envelope cannot be accepted by the new context.
        let disk = try Data(contentsOf: file), frameCount = Captures.frames[103]?.count
        XCTAssertEqual(try request(103, 1, owner: initial.owner, event: burst), 2)
        XCTAssertEqual(try request(101, 1, owner: initial.owner, event: burst), 2)
        XCTAssertEqual(try Data(contentsOf: file), disk)
        XCTAssertEqual(Captures.frames[103]?.count, frameCount)
        XCTAssertEqual(try request(103, 2), 1)
        XCTAssertEqual(try request(102, 2), 1)
        let other = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: b.appendingPathComponent("FieldLog/workspace.json")))
        XCTAssertTrue(other.tasks.isEmpty)
        XCTAssertTrue(Captures.owners.isEmpty)
        print("PASS C-entry: actual TaskEditor + WorkspaceRepository Unicode/multiline save; close; fresh repository/context reopen; same-origin burst->Save; late old-owner refusal; two context storage isolation; all owners revoked")
    }

    @MainActor func testAtomicBatchStagesActualReducerAndPublishesOnceBeforeDurableEffect() async throws {
        let directory = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"])).appendingPathComponent("batch")
        let surface = Surface()
        let app = try await PublicAndroidApplication(surface: surface, selectedProfile: surface.profile.rawValue, directory: directory)
        let owner = try XCTUnwrap(app.host.owner)
        func event(_ id: String, _ kind: UIEventKind, _ value: UIValue = .null) throws -> UIEventEnvelope {
            let captured = app.presentation.snapshot
            return UIEventEnvelope(revision: captured.document.revision, identity: try XCTUnwrap(captured.identity(for: id)), event: kind, value: value)
        }
        try app.send(owner: owner, originalEnvelope: JSONEncoder().encode(event("task.title", .textChange, .string("ready"))))
        let before = app.presentation.snapshot, priorState = app.presentation.state
        let file = directory.appendingPathComponent("FieldLog/workspace.json"), priorDisk = try Data(contentsOf: file)
        let first = try event("task.title", .textChange, .string("Batch 🧪\nsecond line"))
        let save = try event("task.save", .activate)
        var publications = 0
        let unsubscribe = app.presentation.observe { _ in publications += 1 }
        defer { unsubscribe() }
        XCTAssertThrowsError(try app.sendBatch(owner: owner, originalEnvelopes: JSONEncoder().encode([first, save, first])))
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(app.presentation.snapshot.document, before.document)
        XCTAssertEqual(app.presentation.state, priorState)
        XCTAssertEqual(try Data(contentsOf: file), priorDisk)
        try app.sendBatch(owner: owner, originalEnvelopes: JSONEncoder().encode([first, save]))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(app.presentation.snapshot.document.revision, before.document.revision + 1)
        XCTAssertTrue(app.presentation.state.saving)
        XCTAssertEqual(try Data(contentsOf: file), priorDisk)
        XCTAssertThrowsError(try app.send(owner: owner, originalEnvelope: JSONEncoder().encode(first)))
        try await app.settle()
        XCTAssertTrue(app.presentation.state.saved)
        XCTAssertEqual(publications, 2, "One admitted batch publication, one async save-completion publication")
        await app.close()
        let repository = try WorkspaceRepository(directory: directory.appendingPathComponent("FieldLog"))
        let saved = await repository.snapshot()
        XCTAssertEqual(saved.tasks.map(\.title), ["Batch 🧪\nsecond line"])
        await repository.close()
        XCTAssertNil(surface.owner)
        print("PASS atomic batch: all original routes + actual reducer before repository effect; failure leaves state/disk/publications unchanged; one synchronous publication; separate async completion; fresh real repository reads exact data")
    }
    @MainActor func testMultipleTasksCompletionReorderUnsentQueueAndDurableReopen() async throws {
        let directory = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["FIELDLOG_WORKSPACE"])).appendingPathComponent("workspace-flow")
        let surface = Surface()
        let app = try await PublicAndroidApplication(surface: surface, selectedProfile: surface.profile.rawValue, directory: directory)
        let owner = try XCTUnwrap(app.host.owner)
        func event(_ id: String, _ kind: UIEventKind = .activate, _ value: UIValue = .null) throws -> UIEventEnvelope {
            let captured = app.presentation.snapshot
            return UIEventEnvelope(revision: captured.document.revision, identity: try XCTUnwrap(captured.identity(for: id)), event: kind, value: value)
        }
        func send(_ id: String, _ kind: UIEventKind = .activate, _ value: UIValue = .null) throws {
            try app.send(owner: owner, originalEnvelope: JSONEncoder().encode(event(id, kind, value)))
        }
        func documentText() throws -> String { String(decoding: try JSONEncoder().encode(app.presentation.snapshot.document), as: UTF8.self) }
        let file = directory.appendingPathComponent("FieldLog/workspace.json")
        try send("task.title", .textChange, .string("Inspect roof"))
        try send("task.responsible", .textChange, .string("Jo"))
        try send("task.save")
        XCTAssertTrue(app.presentation.state.saving)
        XCTAssertTrue(app.presentation.workspace.tasks.isEmpty, "No optimistic durable success")
        try await app.settle()
        XCTAssertTrue(app.presentation.state.saved)
        XCTAssertTrue(try documentText().contains("Saved on device"))
        try send("task.new")
        XCTAssertEqual(app.presentation.state.title, "")
        XCTAssertEqual(app.presentation.state.responsible, "")
        XCTAssertFalse(app.presentation.state.canSubmit)
        XCTAssertEqual(app.presentation.workspace.tasks.count, 1)
        try send("task.title", .textChange, .string("Record delivery"))
        try send("task.responsible", .textChange, .string("Sam"))
        try send("task.save")
        try await app.settle()
        let project = try XCTUnwrap(app.presentation.workspace.projects.first).id
        let ordered = app.presentation.workspace.tasks(for: project)
        XCTAssertEqual(ordered.map(\.title), ["Inspect roof", "Record delivery"])
        let first = "task." + ordered[0].id.uuidString.lowercased()
        let second = "task." + ordered[1].id.uuidString.lowercased()
        XCTAssertEqual(app.presentation.workspace.outbox.count, 3)
        let priorDisk = try Data(contentsOf: file), priorSnapshot = app.presentation.snapshot
        let complete = try event(first + ".complete"), move = try event(second + ".up")
        XCTAssertThrowsError(try app.sendBatch(owner: owner, originalEnvelopes: JSONEncoder().encode([complete, move])))
        XCTAssertEqual(try Data(contentsOf: file), priorDisk)
        XCTAssertEqual(app.presentation.snapshot.document, priorSnapshot.document)
        XCTAssertThrowsError(try send(first + ".up"), "First item cannot move up")
        try send(first + ".complete")
        XCTAssertEqual(try Data(contentsOf: file), priorDisk, "Mutation awaits admitted busy publication")
        XCTAssertThrowsError(try app.send(owner: owner, originalEnvelope: JSONEncoder().encode(complete)))
        try await app.settle()
        XCTAssertTrue(try XCTUnwrap(app.presentation.workspace.tasks.first { $0.id == ordered[0].id }).completed)
        try send(second + ".up")
        try await app.settle()
        XCTAssertEqual(app.presentation.workspace.tasks(for: project).map(\.id), [ordered[1].id, ordered[0].id])
        XCTAssertEqual(app.presentation.workspace.outbox.count, 5)
        XCTAssertEqual(app.presentation.workspace.outbox.last?.kind, .taskOrderChanged)
        try send("task.new")
        try send("task.title", .textChange, .string("Unsubmitted editor text"))
        try send("workspace.queue")
        let queue = try documentText()
        XCTAssertTrue(queue.contains("Pending changes (5)"))
        XCTAssertTrue(queue.contains("Not sent"))
        XCTAssertTrue(queue.contains("Checklist reordered"))
        XCTAssertTrue(queue.contains("Task updated: Inspect roof"))
        XCTAssertTrue(queue.contains("Cloud sync isn't connected"))
        try send("workspace.back")
        XCTAssertEqual(app.presentation.state.title, "Unsubmitted editor text", "On-device queue does not discard the open editor")
        // An admitted mutation must finish even when Close arrives immediately.
        try send(first + ".complete")
        await app.close()
        XCTAssertNil(surface.owner)
        let repository = try WorkspaceRepository(directory: directory.appendingPathComponent("FieldLog"))
        let saved = await repository.snapshot()
        XCTAssertEqual(saved.tasks(for: project).map(\.id), [ordered[1].id, ordered[0].id])
        XCTAssertFalse(try XCTUnwrap(saved.tasks.first { $0.id == ordered[0].id }).completed)
        XCTAssertEqual(saved.tasks.map(\.responsible).sorted(), ["Jo", "Sam"])
        XCTAssertEqual(saved.outbox.count, 6)
        XCTAssertEqual(Set(saved.outbox.map(\.id)).count, 6)
        XCTAssertEqual(saved.entries.count, 0)
        await repository.close()
        let reopenedSurface = Surface()
        let reopened = try await PublicAndroidApplication(surface: reopenedSurface, selectedProfile: reopenedSurface.profile.rawValue, directory: directory)
        XCTAssertEqual(reopened.presentation.workspace, saved)
        XCTAssertNotEqual(reopened.host.owner, owner)
        XCTAssertThrowsError(try reopened.send(owner: owner, originalEnvelope: JSONEncoder().encode(complete)))
        await reopened.close()
        print("PASS workspace: two real tasks; clean New task; durable completion and reopen; atomic refusal; reorder; six real unsent outbox changes; queue preserves editor; Close drains admitted write; fresh repository and public owner reopen")
    }

}
