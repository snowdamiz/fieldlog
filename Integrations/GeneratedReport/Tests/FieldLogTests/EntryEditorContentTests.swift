import Foundation
import Testing
import FieldLogModels
import FieldLogStorage
import FieldLogFeatures

private func reviewFolder() -> URL {
  URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("r204-\(UUID())")
}
private func reviewPersist(_ intent: EntrySaveIntent, _ repo: WorkspaceRepository) async -> EntrySaveResult {
  do { return try intent.result(in: await repo.transact { try intent.apply(to: &$0) }) }
  catch { return .failed(error.localizedDescription) }
}

// Negative controls change only the response after a real successful storage transaction.
@Test(arguments: ["draft-id", "draft-project", "draft-note", "commit-id", "commit-project", "commit-note"])
@MainActor func independentResponseMustMatchSubmittedContent(mode: String) async throws {
  let folder = reviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repo = try WorkspaceRepository(directory: folder)
  let seeded = try await repo.transact { try $0.createProject(title: "Response control", site: "") }
  let project = try #require(seeded.projects.first?.id)
  let draft = EntryDraft(projectID: project, title: "Exact title", note: "Submitted\n日本語 e\u{301}", category: .issue, occurredAt: Date(timeIntervalSince1970: 1792600000.125))
  let editor = try EntryEditor(projectID: project, draft: draft) { intent in
    switch await reviewPersist(intent, repo) {
    case .draftSaved(var value):
      if mode.hasSuffix("id") { value.id = UUID() }
      if mode.hasSuffix("project") { value.projectID = UUID() }
      if mode.hasSuffix("note") { value.note = "Unrelated stale note" }
      return .draftSaved(value)
    case .committed(var value):
      if mode.hasSuffix("id") { value.id = UUID() }
      if mode.hasSuffix("project") { value.projectID = UUID() }
      if mode.hasSuffix("note") { value.note = "Unrelated stale note" }
      return .committed(value)
    case .failed(let reason): return .failed(reason)
    }
  }
  if mode.hasPrefix("commit") { try editor.commitDraft() } else { try editor.saveDraft() }
  await editor.waitForSave()
  let snapshot = await repo.snapshot()
  let diskNote = mode.hasPrefix("commit") ? snapshot.entries.first?.note : snapshot.drafts.first?.note
  print("R204 response \(mode): diskExact=\(diskNote?.utf8.elementsEqual(draft.note.utf8) == true) rejected=\(editor.state.failure != nil) uiDraft=\(editor.state.draft.note.debugDescription) uiCommitted=\(editor.state.committed?.note.debugDescription ?? "nil")")
  #expect(diskNote?.utf8.elementsEqual(draft.note.utf8) == true)
  #expect(editor.state.failure != nil, "Mismatched callback must fail closed")
  #expect(editor.state.committed == nil)
  #expect(editor.state.draft.note.utf8.elementsEqual(draft.note.utf8))
  try editor.close(); await repo.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect(await reopened.snapshot() == snapshot)
  await reopened.close()
}

private actor ReviewGate {
  var intents: [EntrySaveIntent] = []
  var pending: [Int: CheckedContinuation<EntrySaveResult, Never>] = [:]
  var admitted: CheckedContinuation<Void, Never>?
  func save(_ intent: EntrySaveIntent) async -> EntrySaveResult {
    let index = intents.count; intents.append(intent)
    return await withCheckedContinuation { pending[index] = $0; admitted?.resume(); admitted = nil }
  }
  func wait(_ count: Int) async {
    if intents.count >= count { return }
    await withCheckedContinuation { admitted = $0 }
  }
  func finish(_ index: Int) { pending.removeValue(forKey: index)?.resume(returning: .draftSaved(intents[index].draft)) }
}

@Test @MainActor func independentCancelledOldResultCannotCompleteRetriedGeneration() async throws {
  let gate = ReviewGate(); let project = UUID()
  let editor = try EntryEditor(projectID: project) { await gate.save($0) }
  try editor.changeNote("old"); try editor.saveDraft(); await gate.wait(1)
  var oldWait: Task<Void, Never>?
  await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
    oldWait = Task { @MainActor in started.resume(); await editor.waitForSave() }
  }
  try editor.cancel(); try editor.changeNote("new"); try editor.saveDraft(); await gate.wait(2)
  await gate.finish(0); await oldWait?.value
  #expect(editor.state.saving && editor.state.draft.note == "new" && editor.state.savedDraft == nil)
  await gate.finish(1); await editor.waitForSave()
  #expect(!editor.state.saving && editor.state.savedDraft?.note == "new")
  try editor.changeNote("edited after save")
  #expect(editor.state.draft.note == "edited after save" && editor.state.savedDraft?.note == "new")
  try editor.close()
}

@Test func independentCanonicalEquivalentChangedRetryMustNotClaimExactCommit() async throws {
  let folder = reviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
  let repo = try WorkspaceRepository(directory: folder)
  let seeded = try await repo.transact { try $0.createProject(title: "UTF8 retry", site: "") }
  let project = try #require(seeded.projects.first?.id)
  let original = EntryDraft(projectID: project, title: "Retry", note: "caf\u{00e9}\n")
  let first = EntrySaveIntent(projectID: project, draft: original, kind: .commit)
  if case .committed = await reviewPersist(first, repo) {} else { Issue.record("Initial commit failed") }
  let before = await repo.snapshot()
  var changed = original; changed.note = "cafe\u{301}\n"
  #expect(changed.note == original.note)
  #expect(!changed.note.utf8.elementsEqual(original.note.utf8))
  let retried = await reviewPersist(EntrySaveIntent(projectID: project, draft: changed, kind: .commit), repo)
  switch retried {
  case .failed: break
  case .committed(let entry):
    print("R204 canonical retry accepted: requestedUTF8=\(Array(changed.note.utf8)) actualUTF8=\(Array(entry.note.utf8))")
    Issue.record("Changed UTF8 note was reported committed instead of refusing conflicting retry")
  default: Issue.record("Unexpected response")
  }
  let after = await repo.snapshot()
  #expect(after.entries.count == 1 && after.outbox.count == before.outbox.count)
  await repo.close()
  let reopened = try WorkspaceRepository(directory: folder)
  #expect((await reopened.snapshot()).entries[0].note.utf8.elementsEqual(original.note.utf8))
  await reopened.close()
}

@Test func independentResultAccessorMustRejectUnrelatedSameIdentitySnapshot() throws {
  let project = UUID(); let draft = EntryDraft(projectID: project, title: "Intent", note: "Required note")
  let intent = EntrySaveIntent(projectID: project, draft: draft, kind: .draft)
  var workspace = Workspace(); try workspace.createProject(id: project, title: "Project", site: "")
  var changed = draft; changed.note = "Different saved content"
  try workspace.saveDraft(changed)
  #expect(throws: (any Error).self) { try intent.result(in: workspace) }
}
