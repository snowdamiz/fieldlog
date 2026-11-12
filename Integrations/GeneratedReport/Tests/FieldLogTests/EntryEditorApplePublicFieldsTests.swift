#if canImport(SwiftUI)
import Foundation
import Testing
import FieldLogModels
import FieldLogStorage
import FieldLogFeatures
import MixerApple
import MixerUI

@MainActor private func publicEntryEdit(_ host: MixerUIHost, _ value: String) throws -> RoutedUIAction {
  let snapshot = host.snapshot
  let identity = try #require(snapshot.identity(for: snapshot.document.root.id))
  return try host.route(UIEventEnvelope(revision: snapshot.document.revision, identity: identity,
    event: .textChange, value: .string(value)))
}

@Test @MainActor func applePublicEntryFieldsPersistLongNoteDatePhotoAndReopen() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fieldlog-public-entry-r328-\(UUID())")
  defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let seeded = try await repository.transact { try $0.createProject(title: "Public Apple entries", site: "") }
  let project = try #require(seeded.projects.first?.id)
  let save: @Sendable (EntrySaveIntent) async -> EntrySaveResult = { intent in
    do { return try intent.result(in: await repository.transact { try intent.apply(to: &$0) }) }
    catch { return .failed(error.localizedDescription) }
  }
  let owner = try EntryEditorAppleHost(draft: EntryDraft(projectID: project), save: save)
  let note = String(repeating: "👨‍👩‍👧‍👦", count: 4000)
  #expect(note.utf8.count == 100_000)
  #expect(throws: UIValidationError.limitExceeded("stringBytes")) {
    try MixerUIHost(document: MixerUI.TextField("note", "Note", value: note,
      action: "note.changed", axis: .vertical).document(revision: 1))
  }
  #expect(owner.noteHost.snapshot.textValuePolicy == .longNoteV1)
  owner.receiveTitle(try publicEntryEdit(owner.titleHost, " Public 日本語 "))
  owner.receiveNote(try publicEntryEdit(owner.noteHost, note))
  #expect(owner.noteHost.snapshot.document.root.properties["value"]?.string?.utf8.elementsEqual(note.utf8) == true)
  let date = Date(timeIntervalSince1970: 1_792_600_001.875)
  owner.changeOccurredAt(date); owner.changeCategory(.delivery)
  #expect(await owner.attachPhoto { id in
    _ = try await repository.addPhoto(jpeg: Data([0xff, 0xd8, 0xff, 1]), to: id)
  })
  let photo = try #require(owner.state.draft.attachmentIDs.first)
  #expect(await owner.done {
    do { _ = try await repository.transact { $0.restoration.openDraftID = nil }; return true }
    catch { return false }
  })
  try owner.close(); await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  let stored = try #require((await reopened.snapshot()).drafts.first)
  let replacement = try EntryEditorAppleHost(draft: stored) { intent in
    do { return try intent.result(in: await reopened.transact { try intent.apply(to: &$0) }) }
    catch { return .failed(error.localizedDescription) }
  }
  #expect(replacement.noteHost.snapshot.document.root.properties["value"]?.string?.utf8.elementsEqual(note.utf8) == true)
  #expect(replacement.state.draft.occurredAt == date && replacement.state.draft.category == .delivery)
  #expect(replacement.state.draft.attachmentIDs == [photo])
  #expect(await replacement.commit())
  let final = await reopened.snapshot()
  #expect(final.entries.first?.note.utf8.elementsEqual(note.utf8) == true)
  #expect(final.entries.first?.title == "Public 日本語" && final.entries.first?.attachmentIDs == [photo])
  #expect(final.entries.first?.occurredAt == date && final.drafts.isEmpty)
  try replacement.close(); await reopened.close()
}

@Test @MainActor func applePublicEntryFieldsRejectOversizeAndStaleCallbacksAndFenceClose() async throws {
  let owner = try EntryEditorAppleHost(draft: EntryDraft(projectID: UUID(), title: "Boundary")) { .draftSaved($0.draft) }
  let stale = try publicEntryEdit(owner.noteHost, "Old callback")
  let exact = " e\u{301}\n日本語 "
  owner.receiveNote(try publicEntryEdit(owner.noteHost, exact))
  #expect(owner.state.draft.note.utf8.elementsEqual(exact.utf8))
  owner.receiveNote(stale)
  #expect(owner.eventFailure != nil && owner.state.draft.note.utf8.elementsEqual(exact.utf8))
  #expect(throws: UIRoutingError.invalidValue) {
    try publicEntryEdit(owner.noteHost, String(repeating: "x", count: 100_001))
  }
  #expect(owner.state.draft.note.utf8.elementsEqual(exact.utf8))
  #expect(await owner.saveDraft())
  let before = try publicEntryEdit(owner.noteHost, "Closed callback")
  try owner.close()
  owner.receiveNote(before)
  #expect(owner.state.draft.note.utf8.elementsEqual(exact.utf8) && owner.isClosed)
  #expect(throws: UIRoutingError.disabledNode) { try publicEntryEdit(owner.noteHost, "After close") }
}

@Test @MainActor func applePublicEntryFieldsPreserveNormalizationAndRejectNULSave() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fieldlog-public-bytes-r328-\(UUID())")
  defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let seeded = try await repository.transact { try $0.createProject(title: "Exact bytes", site: "") }
  let project = try #require(seeded.projects.first?.id)
  let owner = try EntryEditorAppleHost(draft: EntryDraft(projectID: project, title: "Bytes")) { intent in
    do { return try intent.result(in: await repository.transact { try intent.apply(to: &$0) }) }
    catch { return .failed(error.localizedDescription) }
  }
  owner.receiveNote(try publicEntryEdit(owner.noteHost, "é"))
  #expect(await owner.saveDraft())
  let exact = "e\u{301}"
  owner.receiveNote(try publicEntryEdit(owner.noteHost, exact))
  #expect(owner.hasUnsavedChanges)
  #expect(owner.noteHost.snapshot.document.root.properties["value"]?.string?.utf8.elementsEqual(exact.utf8) == true)
  #expect(await owner.saveDraft())
  let valid = await repository.snapshot()
  #expect(valid.drafts.first?.note.utf8.elementsEqual(exact.utf8) == true)
  owner.receiveNote(try publicEntryEdit(owner.noteHost, "zero\0byte"))
  #expect(!(await owner.commit()) && owner.state.failure != nil)
  #expect(owner.state.draft.note.utf8.elementsEqual("zero\0byte".utf8))
  #expect(await repository.snapshot() == valid)
  try owner.close(); await repository.close()
}

private actor PublicEntryPhotoGate {
  private var pending: CheckedContinuation<Void, Never>?
  private var admission: CheckedContinuation<Void, Never>?
  func hold() async {
    await withCheckedContinuation { pending = $0; admission?.resume(); admission = nil }
  }
  func wait() async {
    if pending != nil { return }
    await withCheckedContinuation { admission = $0 }
  }
  func finish() { pending?.resume(); pending = nil }
}

@Test @MainActor func applePublicEntryFieldsDisableDuringPhotoAndFenceClosedCallbacks() async throws {
  let gate = PublicEntryPhotoGate()
  let owner = try EntryEditorAppleHost(draft: EntryDraft(projectID: UUID(), title: "Photo")) { .draftSaved($0.draft) }
  let late = try publicEntryEdit(owner.noteHost, "Late edit")
  let photo = Task { await owner.attachPhoto { _ in await gate.hold() } }
  await gate.wait()
  #expect(owner.titleHost.snapshot.document.root.properties["disabled"]?.bool == true)
  #expect(owner.noteHost.snapshot.document.root.properties["disabled"]?.bool == true)
  #expect(throws: UIRoutingError.disabledNode) { try publicEntryEdit(owner.noteHost, "During photo") }
  owner.receiveNote(late)
  #expect(owner.state.draft.note.isEmpty)
  try owner.close()
  let closed = owner.state
  await gate.finish()
  #expect(!(await photo.value))
  owner.receiveTitle(late); owner.receiveNote(late)
  #expect(owner.state == closed && owner.state.closed)
}
#endif
