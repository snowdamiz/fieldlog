#if canImport(SwiftUI)
import Foundation
import Testing
import FieldLogModels
import FieldLogStorage
import FieldLogFeatures

private actor AppleEntrySaveGate {
  var calls: [EntrySaveIntent] = []
  var cancelled: [Bool] = []
  var pending: CheckedContinuation<EntrySaveResult, Never>?
  var admission: CheckedContinuation<Void, Never>?
  func save(_ intent: EntrySaveIntent) async -> EntrySaveResult {
    calls.append(intent)
    let result: EntrySaveResult = await withCheckedContinuation {
      pending = $0; admission?.resume(); admission = nil
    }
    cancelled.append(Task.isCancelled)
    return result
  }
  func wait() async {
    if pending != nil { return }
    await withCheckedContinuation { admission = $0 }
  }
  func finish(_ result: EntrySaveResult) { pending?.resume(returning: result); pending = nil }
}

@Test @MainActor func appleEntryHostDurableFieldsMergedPhotosDoneReopenAndCommit() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apple-entry-r270-\(UUID())")
  defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let seeded = try await repository.transact { try $0.createProject(title: "iOS bridge", site: "") }
  let project = try #require(seeded.projects.first?.id)
  let draft = EntryDraft(projectID: project)
  let save: @Sendable (EntrySaveIntent) async -> EntrySaveResult = { intent in
    do { return try intent.result(in: await repository.transact { try intent.apply(to: &$0) }) }
    catch { return .failed(error.localizedDescription) }
  }
  let owner = try EntryEditorAppleHost(draft: draft, save: save)
  let note = String(repeating: "👨‍👩‍👧‍👦", count: 4000)
  let date = Date(timeIntervalSince1970: 1792600001.875)
  owner.changeTitle("  Check 日本語  "); owner.changeNote(note)
  owner.changeCategory(.delivery); owner.changeOccurredAt(date)
  #expect(owner.state.draft.note.utf8.count == 100000)
  let attached = await owner.attachPhoto { id in
    _ = try await repository.addPhoto(jpeg: Data([0xff,0xd8,0xff,1]), to: id)
  }
  #expect(attached)
  #expect(owner.state.draft.attachmentIDs.count == 1)
  let photo = try #require(owner.state.draft.attachmentIDs.first)
  let done = await owner.done {
    do { _ = try await repository.transact { $0.restoration.openDraftID = nil }; return true }
    catch { return false }
  }
  #expect(done && !owner.hasUnsavedChanges)
  let saved = await repository.snapshot()
  #expect(saved.drafts.first?.note.utf8.elementsEqual(note.utf8) == true)
  #expect(saved.drafts.first?.category == .delivery && saved.drafts.first?.occurredAt == date)
  #expect(saved.drafts.first?.attachmentIDs == [photo] && saved.restoration.openDraftID == nil)
  #expect(saved.outbox.count == 1 && saved.entries.isEmpty)
  try owner.close(); await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  let restored = try #require((await reopened.snapshot()).drafts.first)
  let second = try EntryEditorAppleHost(draft: restored) { intent in
    do { return try intent.result(in: await reopened.transact { try intent.apply(to: &$0) }) }
    catch { return .failed(error.localizedDescription) }
  }
  second.changeNote(note + "x")
  #expect(!(await second.saveDraft()) && second.state.failure != nil)
  #expect(await reopened.snapshot() == saved)
  second.changeNote("zero\0byte")
  #expect(!(await second.commit()) && second.state.failure != nil)
  #expect(await reopened.snapshot() == saved)
  second.changeNote(note); second.changeTitle("  Final 日本語  ")
  #expect(await second.commit())
  #expect(!(await second.commit()))
  let final = await reopened.snapshot()
  #expect(final.drafts.isEmpty && final.entries.count == 1 && final.outbox.count == 2)
  #expect(final.entries.first?.title == "Final 日本語")
  #expect(final.entries.first?.note.utf8.elementsEqual(note.utf8) == true)
  #expect(final.entries.first?.projectID == project && final.entries.first?.occurredAt == date)
  #expect(final.entries.first?.category == .delivery && final.entries.first?.attachmentIDs == [photo])
  try second.close(); await reopened.close()
}

@Test @MainActor func appleEntryHostCapturesIntentRejectsReentryAndRetainsExactFailure() async throws {
  let gate = AppleEntrySaveGate()
  let owner = try EntryEditorAppleHost(draft: EntryDraft(projectID: UUID())) { await gate.save($0) }
  owner.changeTitle("Exact"); owner.changeNote(" e\u{301}\n日本語 ")
  let captured = owner.state.draft
  let save = Task { await owner.saveDraft() }
  await gate.wait()
  owner.changeNote("Ignored while saving")
  #expect(owner.state.draft == captured && owner.inputUnavailable)
  #expect(!(await owner.commit()))
  #expect(await gate.calls.count == 1)
  #expect(await gate.calls[0].draft.note.utf8.elementsEqual(captured.note.utf8))
  await gate.finish(.failed("Disk full")); #expect(!(await save.value))
  #expect(owner.state.draft == captured && owner.state.failure == "Disk full")
  let retry = Task { await owner.done { Issue.record("Failed save must not close restoration"); return true } }
  await gate.wait()
  var wrong = captured; wrong.note = " é\n日本語 "
  await gate.finish(.draftSaved(wrong))
  #expect(!(await retry.value) && owner.state.failure != nil)
  #expect(owner.state.draft.note.utf8.elementsEqual(captured.note.utf8))
  try owner.close()
}

@Test @MainActor func appleEntryHostCloseFencesCancellationIgnoringSaveAndReplacement() async throws {
  let gate = AppleEntrySaveGate()
  let draft = EntryDraft(projectID: UUID(), title: "Late")
  let owner = try EntryEditorAppleHost(draft: draft) { await gate.save($0) }
  let save = Task { await owner.commit() }
  await gate.wait()
  try owner.close()
  let closed = owner.state
  let replacement = try EntryEditorAppleHost(draft: draft) { _ in .failed("Unused") }
  var workspace = Workspace()
  try workspace.createProject(id: draft.projectID, title: "Late", site: "")
  try workspace.saveDraft(draft); try workspace.commitDraft(draft.id)
  let entry = try #require(workspace.entries.first)
  await gate.finish(.committed(entry))
  #expect(!(await save.value))
  #expect(await gate.cancelled == [true])
  #expect(owner.state == closed && owner.state.closed && owner.state.committed == nil)
  #expect(replacement.state.committed == nil && !replacement.isClosed)
  owner.changeTitle("Late callback"); #expect(owner.state == closed)
  try replacement.close()
}

@Test @MainActor func appleEntryHostDoneCloseFailureRetainsDraftAndPhotoFailureDoesNotCommit() async throws {
  let owner = try EntryEditorAppleHost(draft: EntryDraft(projectID: UUID(), title: "Keep")) {
    .draftSaved($0.draft)
  }
  #expect(!(await owner.done { false }))
  #expect(owner.state.savedDraft != nil && owner.state.committed == nil && !owner.isClosed)
  #expect(!(await owner.attachPhoto { _ in throw FieldLogError.storage("Photo disk full") }))
  #expect(owner.eventFailure != nil && owner.state.committed == nil)
  try owner.close()
}
#endif
