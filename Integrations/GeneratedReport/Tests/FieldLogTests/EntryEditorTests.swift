import Foundation
import Testing
import FieldLogModels
import FieldLogStorage
import FieldLogFeatures

private func entryFolder() -> URL {
  URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    .appendingPathComponent("entry-r198-\(UUID())")
}
private func persist(_ intent: EntrySaveIntent, in repository: WorkspaceRepository) async -> EntrySaveResult {
  do {
    let snapshot = try await repository.transact { try intent.apply(to: &$0) }
    return try intent.result(in: snapshot)
  } catch { return .failed(error.localizedDescription) }
}
private actor EntryGate {
  var calls: [EntrySaveIntent] = []
  var cancelled: [Bool] = []
  private var continuation: CheckedContinuation<EntrySaveResult, Never>?
  private var admission: CheckedContinuation<Void, Never>?
  func save(_ intent: EntrySaveIntent) async -> EntrySaveResult {
    calls.append(intent)
    let result: EntrySaveResult = await withCheckedContinuation {
      continuation = $0; admission?.resume(); admission = nil
    }
    cancelled.append(Task.isCancelled)
    return result
  }
  func wait(count: Int = 1) async {
    if calls.count >= count { return }
    await withCheckedContinuation { admission = $0 }
  }
  func finish(_ value: EntrySaveResult) { continuation?.resume(returning: value); continuation = nil }
}

@Test @MainActor func entryEditorDurableSaveReopenCommitPreservesAllFields() async throws {
  let folder = entryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let original = try await repository.transact { try $0.createProject(title: "Entry site", site: "") }
  let project = try #require(original.projects.first?.id)
  let draft = EntryDraft(projectID: project, title: "  Observation  ", note: "Before",
    category: .issue, occurredAt: Date(timeIntervalSince1970: 1792600000.125))
  _ = try await repository.transact { try $0.saveDraft(draft) }
  _ = try await repository.addPhoto(jpeg: Data([0xff, 0xd8, 0xff, 1]), to: draft.id)
  let seeded = await repository.snapshot()
  let withPhoto = try #require(seeded.drafts.first)
  let editor = try EntryEditor(projectID: project, draft: withPhoto) { await persist($0, in: repository) }
  let prefix = "  日本語\n\nالعربية e\u{301} 👨‍👩‍👧‍👦\n"
  let remainder = 100000 - prefix.utf8.count
  let note = prefix + String(repeating: "界", count: remainder / 3) + String(repeating: " ", count: remainder % 3)
  #expect(note.utf8.count == 100000)
  let occurredAt = Date(timeIntervalSince1970: 1792600001.875)
  try editor.changeTitle("  Check 日本語  ")
  try editor.changeNote(note)
  try editor.changeCategory(.delivery)
  try editor.changeOccurredAt(occurredAt)
  try editor.saveDraft(); try editor.saveDraft()
  await editor.waitForSave()
  #expect(!editor.state.saving && editor.state.failure == nil)
  let saved = try #require(editor.state.savedDraft)
  #expect(saved.id == draft.id && saved.projectID == project && saved.attachmentIDs == withPhoto.attachmentIDs)
  #expect(saved.note.utf8.elementsEqual(note.utf8) && saved.category == .delivery && saved.occurredAt == occurredAt)
  let beforeClose = await repository.snapshot()
  #expect(beforeClose.entries.isEmpty && beforeClose.outbox.count == 1)
  #expect(beforeClose.restoration.openDraftID == draft.id)
  try editor.close(); await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect(await reopened.snapshot() == beforeClose)
  let restored = try #require((await reopened.snapshot()).drafts.first)
  let editor2 = try EntryEditor(projectID: project, draft: restored) { await persist($0, in: reopened) }
  #expect(editor2.state.draft == saved)
  try editor2.commitDraft(); try editor2.commitDraft()
  await editor2.waitForSave(); try editor2.commitDraft()
  let entry = try #require(editor2.state.committed)
  #expect(entry.id == draft.id && entry.projectID == project)
  #expect(entry.note.utf8.elementsEqual(note.utf8) && entry.title == "Check 日本語")
  #expect(entry.category == .delivery && entry.occurredAt == occurredAt && entry.attachmentIDs == withPhoto.attachmentIDs)
  let final = await reopened.snapshot()
  #expect(final.entries.count == 1 && final.drafts.isEmpty && final.outbox.count == 2)
  #expect(final.outbox.filter { $0.kind == .entrySaved && $0.recordID == draft.id }.count == 1)
  #expect(final.restoration.openDraftID == nil)
  try editor2.close(); await reopened.close()
  let committedReopen = try WorkspaceRepository(directory: folder)
  #expect(await committedReopen.snapshot() == final)
  #expect(try Data(contentsOf: await committedReopen.photoURL(withPhoto.attachmentIDs[0])) == Data([0xff, 0xd8, 0xff, 1]))
  await committedReopen.close()
}

@Test @MainActor func entryEditorAllCategoriesAndByteBoundary() async throws {
  let project = UUID(); let gate = EntryGate()
  let editor = try EntryEditor(projectID: project) { await gate.save($0) }
  for category in EntryCategory.allCases { try editor.changeCategory(category); #expect(editor.state.draft.category == category) }
  let boundary = String(repeating: "👨‍👩‍👧‍👦", count: 4000)
  #expect(boundary.utf8.count == 100000)
  try Workspace.text(boundary, label: "Note", maximum: 100000)
  try editor.changeNote(boundary + "x"); try editor.saveDraft()
  #expect(editor.state.failure != nil && !editor.state.saving)
  #expect(editor.state.draft.note.utf8.count == 100001)
  try editor.changeNote("\0"); try editor.saveDraft()
  #expect(editor.state.failure != nil)
  try editor.changeNote("valid\n"); try editor.changeTitle(" \n"); try editor.commitDraft()
  #expect(editor.state.failure != nil)
  try editor.close()
}

@Test @MainActor func entryEditorBlankDraftIsDurableButBlankCommitIsRejected() async throws {
  let folder = entryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let original = try await repository.transact { try $0.createProject(title: "Blank", site: "") }
  let project = try #require(original.projects.first?.id)
  let editor = try EntryEditor(projectID: project) { await persist($0, in: repository) }
  try editor.changeNote(String(repeating: "界", count: 33333) + "a")
  try editor.saveDraft(); await editor.waitForSave()
  #expect(editor.state.savedDraft?.note.utf8.count == 100000)
  let saved = await repository.snapshot()
  try editor.commitDraft(); await editor.waitForSave()
  #expect(editor.state.failure != nil && !editor.state.saving)
  #expect(await repository.snapshot() == saved)
  try editor.close(); await repository.close()
}

@Test @MainActor func entryEditorFailureRetainsInputAndAllowsEditRetry() async throws {
  let gate = EntryGate(); let project = UUID()
  let editor = try EntryEditor(projectID: project) { await gate.save($0) }
  try editor.changeTitle("Retry"); try editor.changeNote(" exact\n日本語 ")
  let draft = editor.state.draft
  try editor.saveDraft(); await gate.wait()
  try editor.commitDraft(); try editor.changeNote("lost")
  #expect(editor.state.draft == draft && editor.state.saving)
  #expect(await gate.calls.count == 1)
  await gate.finish(.failed("Disk full")); await editor.waitForSave()
  #expect(editor.state.failure == "Disk full" && !editor.state.saving && editor.state.draft == draft)
  try editor.changeCategory(.progress); #expect(editor.state.failure == nil)
  try editor.saveDraft()
  await gate.wait(count: 2)
  await gate.finish(.draftSaved(editor.state.draft))
  await editor.waitForSave()
  #expect(editor.state.savedDraft?.category == .progress && editor.state.failure == nil)
  try editor.close()
}

@Test(arguments: [false, true]) @MainActor func entryEditorCancelOrCloseFencesLateDeliveryAndKnownWaitDrains(close: Bool) async throws {
  let gate = EntryGate(); let project = UUID()
  let editor = try EntryEditor(projectID: project) { await gate.save($0) }
  var deliveries = 0
  let observation = editor.observe { _ in deliveries += 1 }
  try editor.changeTitle("Cancel"); try editor.saveDraft(); await gate.wait()
  var drained = false
  var waiter: Task<Void, Never>?
  await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
    waiter = Task { @MainActor in started.resume(); await editor.waitForSave(); drained = true }
  }
  #expect(!drained)
  let draft = editor.state.draft
  if close { try editor.close() } else { try editor.cancel() }
  #expect(!editor.state.saving && editor.state.failure == nil)
  let cancelledState = editor.state; let beforeDelivery = deliveries
  await gate.finish(.draftSaved(draft))
  await waiter?.value
  #expect(drained && editor.state == cancelledState && deliveries == beforeDelivery)
  #expect(await gate.cancelled == [true])
  if close { #expect(throws: (any Error).self) { try editor.saveDraft() } }
  else { try editor.changeTitle("Editable after cancel"); #expect(editor.state.draft.title == "Editable after cancel") }
  editor.removeObserver(observation); try editor.close()
}

@Test @MainActor func entryEditorCancelDoesNotUndoCommittedDisk() async throws {
  let folder = entryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let original = try await repository.transact { try $0.createProject(title: "Atomic", site: "") }
  let project = try #require(original.projects.first?.id); let gate = EntryGate()
  let editor = try EntryEditor(projectID: project) { intent in
    let result = await persist(intent, in: repository)
    _ = await gate.save(intent)
    return result
  }
  try editor.changeTitle("Already on disk"); try editor.commitDraft(); await gate.wait()
  var waiter: Task<Void, Never>?
  await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
    waiter = Task { @MainActor in started.resume(); await editor.waitForSave() }
  }
  try editor.cancel(); await gate.finish(.failed("Ignored gate response")); await waiter?.value
  #expect(editor.state.committed == nil && !editor.state.saving)
  let disk = await repository.snapshot()
  #expect(disk.entries.count == 1 && disk.outbox.count == 2)
  try editor.close(); await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect(await reopened.snapshot() == disk); await reopened.close()
}

@Test @MainActor func entryEditorRejectsWrongProjectAndInvalidDateBeforePersistence() async throws {
  let project = UUID(); let wrong = UUID(); let gate = EntryGate()
  #expect(throws: FieldLogError.self) {
    try EntryEditor(projectID: project, draft: EntryDraft(projectID: wrong)) { await gate.save($0) }
  }
  let editor = try EntryEditor(projectID: project) { await gate.save($0) }
  try editor.changeTitle("Date"); try editor.changeOccurredAt(Date(timeIntervalSinceReferenceDate: .nan))
  try editor.saveDraft(); #expect(editor.state.failure != nil && !editor.state.saving)
  #expect(await gate.calls.isEmpty); try editor.close()
}

@Test func entryIntentSameProjectGuardAndRetryNeverDuplicateOutboxOrResurrectDraft() async throws {
  let folder = entryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let first = UUID(), second = UUID()
  let original = try await repository.transact {
    try $0.createProject(id: first, title: "One", site: "")
    try $0.createProject(id: second, title: "Two", site: "")
  }
  let draft = EntryDraft(projectID: first, title: "Commit", note: "Exact\n")
  let save = EntrySaveIntent(projectID: first, draft: draft, kind: .draft)
  _ = await persist(save, in: repository)
  var impostor = draft; impostor.projectID = second
  let wrong = EntrySaveIntent(projectID: second, draft: impostor, kind: .draft)
  let beforeWrong = await repository.snapshot()
  if case .failed = await persist(wrong, in: repository) {} else { Issue.record("Wrong-project overwrite succeeded") }
  #expect(await repository.snapshot() == beforeWrong)
  let commit = EntrySaveIntent(projectID: first, draft: draft, kind: .commit)
  _ = await persist(commit, in: repository); _ = await persist(commit, in: repository)
  let committed = await repository.snapshot()
  #expect(committed.entries.count == 1 && committed.outbox.count == original.outbox.count + 1)
  if case .failed = await persist(save, in: repository) {} else { Issue.record("Committed draft resurrected") }
  #expect(await repository.snapshot() == committed)
  var changed = draft; changed.note = "Conflict"
  if case .failed = await persist(EntrySaveIntent(projectID: first, draft: changed, kind: .commit), in: repository) {} else { Issue.record("Conflicting retry succeeded") }
  #expect(await repository.snapshot() == committed); await repository.close()
}

@Test @MainActor func entryEditorConcurrentAttachmentImportIsRetainedInSaveResult() async throws {
  let folder = entryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let original = try await repository.transact { try $0.createProject(title: "Photo", site: "") }
  let project = try #require(original.projects.first?.id)
  let draft = EntryDraft(projectID: project, title: "Retain photo")
  _ = try await repository.transact { try $0.saveDraft(draft) }
  let editor = try EntryEditor(projectID: project, draft: draft) { await persist($0, in: repository) }
  let imported = try await repository.addPhoto(jpeg: Data([0xff, 0xd8, 0xff, 2]), to: draft.id)
  let photos = try #require(imported.drafts.first?.attachmentIDs)
  try editor.saveDraft(); await editor.waitForSave()
  #expect(editor.state.draft.attachmentIDs == photos)
  try editor.commitDraft(); await editor.waitForSave()
  #expect(editor.state.committed?.attachmentIDs == photos)
  try editor.close(); await repository.close()
}

@Test(arguments: ["ascii", "emoji", "combining"]) @MainActor func entryEditorExactUTF8BoundariesUseUnchangedModel(kind: String) async throws {
  let note: String
  switch kind {
  case "ascii": note = String(repeating: "a", count: 100000)
  case "emoji": note = String(repeating: "👨‍👩‍👧‍👦", count: 4000)
  default: note = String(repeating: "e\u{301}", count: 33333) + "\n"
  }
  #expect(note.utf8.count == 100000)
  try Workspace.text(note, label: "Note", maximum: 100000)
  #expect(throws: FieldLogError.self) { try Workspace.text(note + "x", label: "Note", maximum: 100000) }
  let folder = entryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repository = try WorkspaceRepository(directory: folder)
  let seed = try await repository.transact { try $0.createProject(title: "UTF8", site: "") }
  let project = try #require(seed.projects.first?.id)
  let editor = try EntryEditor(projectID: project) { await persist($0, in: repository) }
  try editor.changeNote(note); try editor.saveDraft(); await editor.waitForSave()
  #expect(editor.state.failure == nil && editor.state.savedDraft?.note.utf8.elementsEqual(note.utf8) == true)
  let saved = await repository.snapshot()
  try editor.changeNote(note + "x"); try editor.saveDraft(); await editor.waitForSave()
  #expect(editor.state.failure != nil && !editor.state.saving && editor.state.draft.note.utf8.count == 100001)
  #expect(await repository.snapshot() == saved)
  try editor.changeNote("zero\0byte"); try editor.saveDraft(); await editor.waitForSave()
  #expect(editor.state.failure != nil)
  #expect(await repository.snapshot() == saved)
  try editor.close(); await repository.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect((await reopened.snapshot()).drafts.first?.note.utf8.elementsEqual(note.utf8) == true)
  await reopened.close()
}
