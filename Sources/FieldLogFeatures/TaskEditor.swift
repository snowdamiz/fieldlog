import Foundation
import FieldLogModels
import MixerCore

public struct TaskEditorState: Equatable, Sendable {
  public var title = ""
  public var responsible = ""
  public var saving = false
  public var saved = false
  public var failure: String?
  public init() {}
  public var canSubmit: Bool {
    !saving && !saved && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

public enum TaskSaveResult: Sendable {
  case saved
  case failed(String)
}

/// An actual native FieldLog feature using only the public, revision-pinned Mixer
/// state/effect API. Persistence stays in the app's existing serialized repository.
@MainActor public final class TaskEditor {
  private enum Action: Sendable {
    case title(String), responsible(String), submit, completed(TaskSaveResult)
  }
  private let store: FeatureStore<TaskEditorState, Action>
  public var state: TaskEditorState { store.state }

  public init(save: @escaping @Sendable (String, String) async -> TaskSaveResult) throws {
    store = FeatureStore(initialState: TaskEditorState()) { state, action in
      switch action {
      case .title(let title):
        guard !state.saving && !state.saved else { return [] }
        state.title = title; state.failure = nil
      case .responsible(let responsible):
        guard !state.saving && !state.saved else { return [] }
        state.responsible = responsible; state.failure = nil
      case .submit:
        guard state.canSubmit else { return [] }
        do {
          try Workspace.text(state.title.trimmingCharacters(in: .whitespacesAndNewlines), label: "Task", maximum: 240, required: true)
          try Workspace.text(state.responsible.trimmingCharacters(in: .whitespacesAndNewlines), label: "Responsible person", maximum: 160)
        } catch {
          state.failure = error.localizedDescription
          return []
        }
        state.saving = true; state.failure = nil
        let title = state.title, responsible = state.responsible
        return [.run(id: "task.save") { .completed(await save(title, responsible)) }]
      case .completed(let result):
        guard state.saving else { return [] }
        state.saving = false
        switch result {
        case .saved: state.saved = true; state.failure = nil
        case .failed(let message): state.failure = message
        }
      }
      return []
    }
    try store.transition(.start)
  }
  @discardableResult public func observe(_ handler: @escaping @MainActor @Sendable (TaskEditorState) -> Void) -> UUID { store.observe(handler) }
  public func removeObserver(_ id: UUID) { store.removeObserver(id) }
  public func changeTitle(_ value: String) throws { try store.send(.title(value)) }
  public func changeResponsible(_ value: String) throws { try store.send(.responsible(value)) }
  public func submit() throws { try store.send(.submit) }
  public func waitForSave() async { await store.awaitCurrentEffects() }
  public func close() throws {
    if store.lifecycle != .stopped { try store.transition(.stop) }
  }
}
