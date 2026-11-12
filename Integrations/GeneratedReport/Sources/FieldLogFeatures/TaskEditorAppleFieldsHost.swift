#if canImport(SwiftUI)
import Foundation
import SwiftUI
import MixerApple
import MixerUI

enum TaskEditorAppleFieldsError: Error, Equatable {
  case closed, unavailable, foreignOwner, foreignHost, projectionMismatch, invalidAction
}

/// An immutable link between one private editor owner, its shared source render,
/// and the exact public native-host render installed from that source.
struct TaskEditorAppleFieldsInstallation {
  let ownerID: UUID
  let id: UUID
  let source: UIRenderSnapshot
  let native: UIRenderSnapshot
}

/// Partial public rendering: only the shared fields Section is projected into
/// MixerApple. The app keeps its native navigation, toolbar, errors and disclosure.
@MainActor public final class TaskEditorAppleFieldsHost: ObservableObject {
  public var snapshot: TaskEditorPresentationSnapshot { presentation.snapshot }
  @Published public private(set) var eventFailure: String?
  @Published public private(set) var adapterFailure: String?
  public var isClosed: Bool { closed }
  public var inputUnavailable: Bool {
    closed || installing || adapterFailure != nil || snapshot.renderingFailure != nil || snapshot.outcome != .editing
  }

  let ownerID: UUID
  let nativeHost: MixerUIHost
  private(set) var installation: TaskEditorAppleFieldsInstallation
  private let presentation: TaskEditorPresentation
  private let project: @MainActor (MixerUI.UIDocument) throws -> MixerUI.UIDocument
  private let update: @MainActor (MixerUIHost, MixerUI.UIDocument) throws -> Void
  private var observation: UUID?
  private var closed = false
  private var installing = false

  public convenience init(save: @escaping @Sendable (String, String) async -> TaskSaveResult) throws {
    try self.init(presentation: TaskEditorPresentation(save: save))
  }

  // The projector injection is internal so host failure behavior can be tested
  // without altering the public renderer or weakening production validation.
  init(presentation: TaskEditorPresentation,
    project: @escaping @MainActor (MixerUI.UIDocument) throws -> MixerUI.UIDocument = TaskEditorAppleFieldsHost.fieldsDocument,
    update: @escaping @MainActor (MixerUIHost, MixerUI.UIDocument) throws -> Void = { host, document in
      _ = try host.update(document)
    }) throws
  {
    let initial = presentation.snapshot
    let document = try project(initial.render.document)
    guard document == (try Self.fieldsDocument(initial.render.document)) else {
      throw TaskEditorAppleFieldsError.projectionMismatch
    }
    let nativeHost = try MixerUIHost(document: document)
    let ownerID = UUID()
    self.ownerID = ownerID
    self.presentation = presentation
    self.project = project
    self.update = update
    self.nativeHost = nativeHost
    installation = TaskEditorAppleFieldsInstallation(ownerID: ownerID, id: UUID(),
      source: initial.render, native: nativeHost.snapshot)
    observation = presentation.observe { [weak self] next in
      guard let self, self.ownerID == ownerID, !self.isClosed else { return }
      self.install(next)
    }
  }

  /// Native toolbar callbacks pass the envelope captured from their displayed
  /// shared snapshot. No callback may remint a current event from a node ID.
  public func send(_ event: UIEventEnvelope) {
    do { try acceptNative(event); eventFailure = nil }
    catch { if !closed && !installing { eventFailure = error.localizedDescription } }
  }

  func acceptNative(_ event: UIEventEnvelope) throws {
    try requireAdmission()
    try presentation.send(event)
  }

  /// All validation and the final shared send are synchronous on MainActor.
  /// RoutedUIAction omits native generation, so the public host first validates
  /// its original envelope; this bridge then revalidates the installed pair.
  func accept(_ action: RoutedUIAction, from host: MixerUIHost,
    installation receipt: TaskEditorAppleFieldsInstallation) throws
  {
    try requireAdmission()
    guard receipt.ownerID == ownerID else { throw TaskEditorAppleFieldsError.foreignOwner }
    guard host === nativeHost else { throw TaskEditorAppleFieldsError.foreignHost }
    guard receipt.id == installation.id else { throw UIRoutingError.staleRevision }
    guard action.revision == receipt.native.document.revision,
      action.revision == receipt.source.document.revision,
      presentation.snapshot.render.document == receipt.source.document,
      host.snapshot.document == receipt.native.document else { throw UIRoutingError.staleRevision }
    guard let nativeIdentity = receipt.native.identity(for: action.nodeID),
      host.snapshot.identity(for: action.nodeID) == nativeIdentity,
      let sourceIdentity = receipt.source.identity(for: action.nodeID),
      presentation.snapshot.render.identity(for: action.nodeID) == sourceIdentity else {
      throw UIRoutingError.staleIdentity
    }
    let nativeEvent = UIEventEnvelope(revision: action.revision, identity: nativeIdentity,
      event: action.event, value: action.value)
    let sourceEvent = try Self.sourceEvent(for: action, native: receipt.native, source: receipt.source)
    guard try host.route(nativeEvent) == action,
      try presentation.snapshot.render.route(sourceEvent) == action else {
      throw TaskEditorAppleFieldsError.invalidAction
    }
    try presentation.send(sourceEvent)
  }

  static func sourceEvent(for action: RoutedUIAction, native: UIRenderSnapshot,
    source: UIRenderSnapshot) throws -> UIEventEnvelope
  {
    guard action.revision == native.document.revision,
      action.revision == source.document.revision else { throw UIRoutingError.staleRevision }
    guard action.event == .textChange,
      action.nodeID == "task.title" || action.nodeID == "task.responsible" else {
      throw TaskEditorAppleFieldsError.invalidAction
    }
    guard let nativeIdentity = native.identity(for: action.nodeID),
      let sourceIdentity = source.identity(for: action.nodeID) else { throw UIRoutingError.staleIdentity }
    let nativeEvent = UIEventEnvelope(revision: action.revision, identity: nativeIdentity,
      event: action.event, value: action.value)
    let sourceEvent = UIEventEnvelope(revision: action.revision, identity: sourceIdentity,
      event: action.event, value: action.value)
    guard try native.route(nativeEvent) == action,
      try source.route(sourceEvent) == action else { throw TaskEditorAppleFieldsError.invalidAction }
    return sourceEvent
  }

  func receive(_ action: RoutedUIAction, from host: MixerUIHost,
    installation receipt: TaskEditorAppleFieldsInstallation)
  {
    do { try accept(action, from: host, installation: receipt); eventFailure = nil }
    catch { record(error, from: host, installation: receipt) }
  }

  func record(_ error: any Error, from host: MixerUIHost,
    installation receipt: TaskEditorAppleFieldsInstallation)
  {
    // Late failures must not overwrite the replacement installation or owner.
    guard !closed, !installing, host === nativeHost, receipt.ownerID == ownerID,
      receipt.id == installation.id else { return }
    eventFailure = error.localizedDescription
  }

  public func waitForSave() async { await presentation.waitForSave() }

  public func close() throws {
    guard !closed else { return }
    // Revoke admission synchronously before any ObservableObject notification.
    closed = true
    defer { objectWillChange.send() }
    if let observation { presentation.removeObserver(observation) }
    observation = nil
    try presentation.close()
  }

  private func requireAdmission() throws {
    guard !closed else { throw TaskEditorAppleFieldsError.closed }
    guard !installing, adapterFailure == nil, snapshot.renderingFailure == nil else {
      throw TaskEditorAppleFieldsError.unavailable
    }
    guard snapshot.outcome == .editing else { throw TaskEditorPresentationError.closed }
  }

  private func install(_ next: TaskEditorPresentationSnapshot) {
    guard !closed else { return }
    guard !installing else {
      adapterFailure = "The task fields could not update. Your text has been kept. Close and reopen the form."
      return
    }
    installing = true
    objectWillChange.send()
    defer { installing = false; objectWillChange.send() }
    guard !closed, adapterFailure == nil, next.renderingFailure == nil else { return }
    do {
      if next.render.document != installation.source.document {
        let document = try project(next.render.document)
        guard document == (try Self.fieldsDocument(next.render.document)) else {
          throw TaskEditorAppleFieldsError.projectionMismatch
        }
        try update(nativeHost, document)
        guard !closed else { return }
        guard nativeHost.snapshot.document == document,
          presentation.snapshot.render.document == next.render.document else {
          throw TaskEditorAppleFieldsError.projectionMismatch
        }
        installation = TaskEditorAppleFieldsInstallation(ownerID: ownerID, id: UUID(),
          source: next.render, native: nativeHost.snapshot)
      }
    } catch {
      // MixerUIHost preserves its old valid render. Revoke admission and disable
      // that render until the form closes, retaining the shared text and failure.
      adapterFailure = "The task fields could not update. Your text has been kept. Close and reopen the form."
    }
  }

  static func fieldsDocument(_ source: MixerUI.UIDocument) throws -> MixerUI.UIDocument {
    _ = try UIValidator(supportedTextFieldAxes: [.horizontal, .vertical]).validate(source)
    guard source.root.id == "task.screen", source.root.kind == .navigation,
      source.root.children.count == 1 else { throw TaskEditorAppleFieldsError.projectionMismatch }
    let list = source.root.children[0]
    guard list.id == "task.form", list.kind == .list,
      let section = list.children.first(where: { $0.id == "task.fields" }),
      section.kind == .section,
      section.children.map(\.id) == ["task.title", "task.responsible"] else {
      throw TaskEditorAppleFieldsError.projectionMismatch
    }
    let title = section.children[0], responsible = section.children[1]
    guard title.kind == .textField, responsible.kind == .textField,
      title.actions == [UIActionBinding(id: "task.title.change", event: .textChange)],
      responsible.actions == [UIActionBinding(id: "task.responsible.change", event: .textChange)],
      title.properties["axis"]?.string == TextFieldAxis.vertical.rawValue,
      responsible.properties["axis"] == nil || responsible.properties["axis"]?.string == TextFieldAxis.horizontal.rawValue else {
      throw TaskEditorAppleFieldsError.projectionMismatch
    }
    var fields = section
    // A projection must retain inherited disabled semantics as well as leaf state.
    if source.root.properties["disabled"]?.bool == true || list.properties["disabled"]?.bool == true {
      fields.properties["disabled"] = .bool(true)
    }
    return MixerUI.UIDocument(schemaVersion: source.schemaVersion, revision: source.revision, root: fields)
  }
}

/// This view renders only editable fields. It supplies no tint, font, navigation,
/// error style or disclosure override; those remain in the consuming native shell.
@MainActor public struct TaskEditorNativeFields: View {
  @ObservedObject private var owner: TaskEditorAppleFieldsHost
  public init(owner: TaskEditorAppleFieldsHost) { self.owner = owner }
  public var body: some View {
    let owner = self.owner
    let host = owner.nativeHost
    let receipt = owner.installation
    MixerNativeView(host: host,
      onAction: { [weak owner] action in owner?.receive(action, from: host, installation: receipt) },
      onEventFailure: { [weak owner] error in owner?.record(error, from: host, installation: receipt) })
      .disabled(owner.inputUnavailable)
  }
}
#endif
