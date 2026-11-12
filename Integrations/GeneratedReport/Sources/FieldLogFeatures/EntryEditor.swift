import Foundation
import FieldLogModels
import MixerCore

public struct EntrySaveIntent: Sendable {
  public enum Kind: Sendable { case draft, commit }
  public let projectID: UUID
  public let draft: EntryDraft
  public let kind: Kind
  public let now: Date

  public init(projectID: UUID, draft: EntryDraft, kind: Kind, now: Date = Date()) {
    self.projectID = projectID; self.draft = draft; self.kind = kind; self.now = now
  }

  public func validate() throws {
    guard draft.projectID == projectID else { throw FieldLogError.missingRecord }
    try Workspace.text(draft.title, label: "Entry title", maximum: 160, required: kind == .commit)
    try Workspace.text(draft.note, label: "Note", maximum: 100000)
    guard draft.occurredAt.timeIntervalSinceReferenceDate.isFinite else {
      throw FieldLogError.validation("Choose a valid entry date.")
    }
  }

  /// Apply only inside the caller's atomic WorkspaceRepository transaction.
  public func apply(to workspace: inout Workspace) throws {
    try validate()
    guard workspace.projects.contains(where: { $0.id == projectID }) else {
      throw FieldLogError.missingRecord
    }
    if let existing = workspace.drafts.first(where: { $0.id == draft.id }),
      existing.projectID != projectID { throw FieldLogError.missingRecord }
    if let entry = workspace.entries.first(where: { $0.id == draft.id }) {
      guard matches(entry) else {
        throw FieldLogError.validation("This entry has already been committed. Reopen it before editing.")
      }
      return
    }
    try workspace.saveDraft(draft)
    workspace.restoration.selectedProjectID = projectID
    workspace.restoration.openDraftID = draft.id
    if kind == .commit { try workspace.commitDraft(draft.id, now: now) }
  }

  private func matches(_ saved: EntryDraft) -> Bool {
    kind == .draft && saved.id == draft.id && saved.projectID == projectID &&
      saved.title.utf8.elementsEqual(draft.title.utf8) &&
      saved.note.utf8.elementsEqual(draft.note.utf8) &&
      saved.category == draft.category && saved.occurredAt == draft.occurredAt &&
      Set(draft.attachmentIDs).isSubset(of: Set(saved.attachmentIDs))
  }

  private func matches(_ saved: LogEntry) -> Bool {
    kind == .commit && saved.id == draft.id && saved.projectID == projectID &&
      saved.title.utf8.elementsEqual(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).utf8) &&
      saved.note.utf8.elementsEqual(draft.note.utf8) &&
      saved.category == draft.category && saved.occurredAt == draft.occurredAt &&
      Set(draft.attachmentIDs).isSubset(of: Set(saved.attachmentIDs))
  }

  fileprivate func validateSuccess(_ result: EntrySaveResult) throws {
    let accepted: Bool
    switch result {
    case .draftSaved(let saved): accepted = matches(saved)
    case .committed(let saved): accepted = matches(saved)
    case .failed: return
    }
    guard accepted else {
      throw FieldLogError.validation("The saved content did not match this entry. Your input has been retained.")
    }
  }

  public func result(in workspace: Workspace) throws -> EntrySaveResult {
    switch kind {
    case .draft:
      guard let saved = workspace.drafts.first(where: { $0.id == draft.id && $0.projectID == projectID }), matches(saved) else {
        throw FieldLogError.missingRecord
      }
      return .draftSaved(saved)
    case .commit:
      guard let entry = workspace.entries.first(where: { $0.id == draft.id && $0.projectID == projectID }), matches(entry) else {
        throw FieldLogError.missingRecord
      }
      return .committed(entry)
    }
  }
}

public enum EntrySaveResult: Sendable {
  case draftSaved(EntryDraft), committed(LogEntry), failed(String)
}

public struct EntryEditorState: Equatable, Sendable {
  public var draft: EntryDraft
  public var saving = false
  public var failure: String?
  public var savedDraft: EntryDraft?
  public var committed: LogEntry?
  public var closed = false
  public init(draft: EntryDraft) { self.draft = draft }
}

@MainActor public final class EntryEditor {
  private enum Action: Sendable {
    case title(String), note(String), category(EntryCategory), date(Date)
    case save(EntrySaveIntent.Kind), completed(EntrySaveIntent, EntrySaveResult), cancel, close
  }
  private let store: FeatureStore<EntryEditorState, Action>
  public var state: EntryEditorState { store.state }

  public init(projectID: UUID, draft: EntryDraft? = nil,
    save: @escaping @Sendable (EntrySaveIntent) async -> EntrySaveResult) throws {
    let initial = draft ?? EntryDraft(projectID: projectID)
    guard initial.projectID == projectID else { throw FieldLogError.missingRecord }
    store = FeatureStore(initialState: EntryEditorState(draft: initial)) { state, action in
      switch action {
      case .cancel, .close:
        state.saving = false; state.failure = nil
        if case .close = action { state.closed = true }
        return [.cancelAll]
      case .completed(let intent, let result):
        guard state.saving && !state.closed else { return [] }
        state.saving = false
        do { try intent.validateSuccess(result) } catch {
          state.failure = error.localizedDescription; return []
        }
        switch result {
        case .failed(let message): state.failure = message
        case .draftSaved(let draft):
          guard intent.kind == .draft, draft.id == state.draft.id, draft.projectID == projectID else {
            state.failure = "The saved draft did not match this editor."; return []
          }
          state.draft = draft; state.savedDraft = draft; state.failure = nil
        case .committed(let entry):
          guard intent.kind == .commit, entry.id == state.draft.id, entry.projectID == projectID else {
            state.failure = "The saved entry did not match this editor."; return []
          }
          state.committed = entry; state.failure = nil
        }
      case .save(let kind):
        guard !state.saving && state.committed == nil && !state.closed else { return [] }
        let intent = EntrySaveIntent(projectID: projectID, draft: state.draft, kind: kind)
        do { try intent.validate() } catch { state.failure = error.localizedDescription; return [] }
        state.saving = true; state.failure = nil
        return [.run(id: "entry.save") {
          guard !Task.isCancelled else { return nil }
          return .completed(intent, await save(intent))
        }]
      default:
        guard !state.saving && state.committed == nil && !state.closed else { return [] }
        switch action {
        case .title(let value): state.draft.title = value
        case .note(let value): state.draft.note = value
        case .category(let value): state.draft.category = value
        case .date(let value): state.draft.occurredAt = value
        default: break
        }
        state.draft.updatedAt = Date(); state.failure = nil
      }
      return []
    }
    try store.transition(.start)
  }

  @discardableResult public func observe(_ observer: @escaping @MainActor @Sendable (EntryEditorState) -> Void) -> UUID { store.observe(observer) }
  public func removeObserver(_ id: UUID) { store.removeObserver(id) }
  public func changeTitle(_ value: String) throws { try store.send(.title(value)) }
  public func changeNote(_ value: String) throws { try store.send(.note(value)) }
  public func changeCategory(_ value: EntryCategory) throws { try store.send(.category(value)) }
  public func changeOccurredAt(_ value: Date) throws { try store.send(.date(value)) }
  public func saveDraft() throws { try store.send(.save(.draft)) }
  public func commitDraft() throws { try store.send(.save(.commit)) }
  public func cancel() throws { try store.send(.cancel) }
  /// Captures currently owned effects; start before cancel/close to drain that batch.
  public func waitForSave() async { await store.awaitCurrentEffects() }
  public func close() throws {
    guard !state.closed else { return }
    try store.send(.close)
    try store.transition(.stop)
  }
}
