import Foundation
import MixerCore
import MixerUI

public enum TaskEditorOutcome: Equatable, Sendable {
  case editing, saved, cancelled, closed
}

public struct TaskEditorPresentationSnapshot: Sendable {
  public let state: TaskEditorState
  public let render: UIRenderSnapshot
  public let navigation: NavigationState
  public let outcome: TaskEditorOutcome
  /// A failed document update stops event admission and leaves the last valid
  /// render intact. Native hosts must disable their input in this state.
  public let renderingFailure: String?
}

public enum TaskEditorPresentationError: Error, Equatable, Sendable {
  case closed, unavailable, invalidAction, revisionExhausted
}

/// FieldLog's actual form contract, navigation and event admission, shared by
/// native consumers. Storage remains an injected asynchronous application service;
/// no filesystem work is performed inside a renderer or synchronous JNI reducer.
@MainActor public final class TaskEditorPresentation {
  public typealias Observer = @MainActor @Sendable (TaskEditorPresentationSnapshot) -> Void
  public private(set) var snapshot: TaskEditorPresentationSnapshot
  private let editor: TaskEditor
  private var reconciler: UIReconciler
  private var observation: UUID?
  private var observers: [UUID: Observer] = [:]
  private var closed = false

  public init(save: @escaping @Sendable (String, String) async -> TaskSaveResult) throws {
    let editor = try TaskEditor(save: save)
    let navigation = try NavigationState(routes: [NavigationRoute(id: "task.editor", name: "newTask")])
    var reconciler = UIReconciler(validator: UIValidator(supportedTextFieldAxes: [.horizontal, .vertical]))
    try reconciler.apply(Self.document(editor.state, outcome: .editing, revision: 1))
    self.editor = editor
    self.reconciler = reconciler
    snapshot = TaskEditorPresentationSnapshot(state: editor.state,
      render: try reconciler.currentSnapshot(), navigation: navigation,
      outcome: .editing, renderingFailure: nil)
    observation = editor.observe { [weak self] state in self?.changed(state) }
  }

  @discardableResult public func observe(_ observer: @escaping Observer) -> UUID {
    let id = UUID()
    observers[id] = observer
    observer(snapshot)
    return id
  }

  public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

  /// A native extension can address the currently displayed shared control. This
  /// still routes through the public SDK snapshot, including disabled/value checks.
  /// Adapters retaining a render across an async boundary use send(_:) instead.
  public func send(nodeID: String, event: UIEventKind, value: UIValue = .null) throws {
    guard let identity = snapshot.render.identity(for: nodeID) else {
      throw UIRoutingError.staleIdentity
    }
    try send(UIEventEnvelope(revision: snapshot.render.document.revision,
      identity: identity, event: event, value: value))
  }

  public func send(_ event: UIEventEnvelope) throws {
    guard !closed && snapshot.outcome == .editing else { throw TaskEditorPresentationError.closed }
    guard snapshot.renderingFailure == nil else { throw TaskEditorPresentationError.unavailable }
    let action = try snapshot.render.route(event)
    switch (action.nodeID, action.actionID, action.event, action.value) {
    case ("task.title", "task.title.change", .textChange, .string(let value)):
      try editor.changeTitle(value)
    case ("task.responsible", "task.responsible.change", .textChange, .string(let value)):
      try editor.changeResponsible(value)
    case ("task.save", "task.save", .activate, .null):
      try editor.submit()
    case ("task.cancel", "task.cancel", .activate, .null):
      var navigation = snapshot.navigation
      navigation.popToRoot()
      publish(editor.state, navigation: navigation, outcome: .cancelled)
    default: throw TaskEditorPresentationError.invalidAction
    }
  }

  public func waitForSave() async { await editor.waitForSave() }

  public func close() throws {
    guard !closed else { return }
    closed = true
    if let observation { editor.removeObserver(observation) }
    observation = nil
    try editor.close()
    var navigation = snapshot.navigation
    navigation.popToRoot()
    publish(editor.state, navigation: navigation,
      outcome: snapshot.outcome == .editing ? .closed : snapshot.outcome)
  }

  private func changed(_ state: TaskEditorState) {
    guard !closed && state != snapshot.state else { return }
    var navigation = snapshot.navigation
    let outcome: TaskEditorOutcome = state.saved ? .saved : snapshot.outcome
    if state.saved { navigation.popToRoot() }
    publish(state, navigation: navigation, outcome: outcome)
  }

  private func publish(_ state: TaskEditorState, navigation: NavigationState, outcome: TaskEditorOutcome) {
    do {
      guard snapshot.render.document.revision < UInt64.max else {
        throw TaskEditorPresentationError.revisionExhausted
      }
      var next = reconciler
      try next.apply(Self.document(state, outcome: outcome,
        revision: snapshot.render.document.revision + 1))
      snapshot = TaskEditorPresentationSnapshot(state: state,
        render: try next.currentSnapshot(), navigation: navigation,
        outcome: outcome, renderingFailure: nil)
      reconciler = next
    } catch {
      snapshot = TaskEditorPresentationSnapshot(state: state, render: snapshot.render,
        navigation: navigation, outcome: outcome,
        renderingFailure: "The task form could not update. Your text has been kept. Close and reopen the form.")
    }
    let published = snapshot
    for observer in Array(observers.values) {
      // A listener may close the owner. Do not then deliver an older open form.
      guard snapshot.render.document.revision == published.render.document.revision,
        snapshot.outcome == published.outcome else { break }
      observer(published)
    }
  }

  private static func document(_ state: TaskEditorState, outcome: TaskEditorOutcome,
    revision: UInt64) -> UIDocument
  {
    let inactive = outcome != .editing || state.saving
    return MixerUI.Navigation("task.screen", title: "New task") {
      MixerUI.List("task.form") {
        MixerUI.Section("task.fields", title: "Task") {
          MixerUI.TextField("task.title", "What needs to happen?", value: state.title,
            action: "task.title.change", axis: .vertical).accessibilityIdentifier("task-title").disabled(inactive)
          MixerUI.TextField("task.responsible", "Responsible person (optional)",
            value: state.responsible, action: "task.responsible.change").disabled(inactive)
        }
        if let failure = state.failure {
          MixerUI.Section("task.failure") {
            // A storage provider's diagnostic must not invalidate the whole form.
            // The complete failure remains in value state; only display is bounded.
            MixerUI.Text("task.failure.message", String(decoding: failure.utf8.prefix(4000), as: UTF8.self), selectable: true)
              .accessibilityLabel("Task could not be saved")
          }
        }
        MixerUI.Section("task.disclosure") {
          MixerUI.Text("task.disclosure.message",
            "A responsibility label is stored locally. It does not invite or notify another person.",
            style: .caption)
        }
        MixerUI.Section("task.actions") {
          MixerUI.Button("task.cancel", "Cancel", action: "task.cancel", role: .cancel).disabled(inactive)
          MixerUI.Button("task.save", state.saving ? "Saving…" : "Add", action: "task.save")
            .disabled(outcome != .editing || !state.canSubmit)
        }
      }
    }.document(revision: revision)
  }
}
