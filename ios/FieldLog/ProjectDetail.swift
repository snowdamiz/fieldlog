import FieldLogModels
import FieldLogFeatures
import enum MixerUI.UIEventKind
import enum MixerUI.UIValue
import struct MixerUI.UINode
import struct MixerUI.UIEventEnvelope
import SwiftUI

struct ProjectDetail: View {
  @EnvironmentObject private var model: WorkspaceModel
  let projectID: UUID
  let onEdit: (EntryDraft) -> Void
  @State private var addingTask = false
  @State private var sharing: ShareDocument?
  @State private var exportError: String?
  var body: some View {
    Group {
      if let workspace = model.workspace,
        let project = workspace.projects.first(where: { $0.id == projectID })
      {
        List {
          Section {
            VStack(alignment: .leading, spacing: 12) {
              if !project.site.isEmpty {
                Label(project.site, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary)
              }
              let tasks = workspace.tasks(for: projectID)
              HStack {
                Text("Project progress").font(.subheadline)
                Spacer()
                Text("\(tasks.filter(\.completed).count) of \(tasks.count)").font(
                  .subheadline.monospacedDigit()
                ).foregroundStyle(.secondary)
              }
              ProgressView(value: workspace.progress(for: projectID)).tint(FieldStyle.green)
            }.padding(.vertical, 6)
          }
          Section {
            ForEach(workspace.tasks(for: projectID)) { task in
              HStack(alignment: .top) {
                Button {
                  model.toggleTask(task.id)
                } label: {
                  HStack(alignment: .top, spacing: 12) {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(
                      .title3
                    ).foregroundStyle(task.completed ? FieldStyle.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                      Text(task.title).foregroundStyle(.primary).strikethrough(task.completed)
                      if !task.responsible.isEmpty {
                        Text(task.responsible).font(.caption).foregroundStyle(.secondary)
                      }
                    }
                  }.padding(.vertical, 3)
                }.buttonStyle(.plain).accessibilityLabel(
                  "\(task.title), \(task.completed ? "completed":"not completed")"
                ).accessibilityHint("Double tap to \(task.completed ? "reopen":"complete") task")
                  .frame(maxWidth: .infinity, alignment: .leading)
                if workspace.tasks(for: projectID).count > 1 {
                  Menu {
                    if let index = workspace.tasks(for: projectID).firstIndex(where: {
                      $0.id == task.id
                    }) {
                      if index > 0 {
                        Button("Move up", systemImage: "arrow.up") {
                          model.moveTask(task.id, offset: -1)
                        }
                      }
                      if index < workspace.tasks(for: projectID).count - 1 {
                        Button("Move down", systemImage: "arrow.down") {
                          model.moveTask(task.id, offset: 1)
                        }
                      }
                    }
                  } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                  }
                  .accessibilityLabel("Task options: \(task.title)")
                }
              }
            }
            .onMove { source, destination in
              var tasks = workspace.tasks(for: projectID)
              tasks.move(fromOffsets: source, toOffset: destination)
              model.reorder(projectID: projectID, ids: tasks.map(\.id))
            }
            Button("Add task", systemImage: "plus") { addingTask = true }
          } header: {
            Text("CHECKLIST")
          }
          let drafts = workspace.drafts.filter { $0.projectID == projectID }
          if !drafts.isEmpty {
            Section("DRAFTS") {
              ForEach(drafts) { draft in
                Button {
                  model.openDraft(draft.id)
                  onEdit(draft)
                } label: {
                  Label {
                    VStack(alignment: .leading, spacing: 4) {
                      Text(draft.title.isEmpty ? "Untitled entry" : draft.title).foregroundStyle(
                        .primary)
                      Text(
                        "Saved draft · \(draft.updatedAt.formatted(date:.abbreviated,time:.shortened))"
                      ).font(.caption).foregroundStyle(.secondary)
                    }
                  } icon: {
                    Image(systemName: "square.and.pencil").foregroundStyle(FieldStyle.green)
                  }
                }
              }
            }
          }
          Section {
            if workspace.entries(for: projectID).isEmpty {
              Text("No entries yet. Add a note, observation or photo from the field.")
                .foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(workspace.entries(for: projectID)) { entry in
              NavigationLink {
                EntryDetail(entry: entry)
              } label: {
                VStack(alignment: .leading, spacing: 6) {
                  HStack {
                    Text(entry.category.rawValue.uppercased()).font(.caption2.weight(.semibold))
                      .foregroundStyle(FieldStyle.green)
                    Spacer()
                    Text(entry.occurredAt, format: .dateTime.month(.abbreviated).day()).font(
                      .caption
                    ).foregroundStyle(.secondary)
                  }
                  Text(entry.title).font(.headline)
                  if !entry.note.isEmpty {
                    Text(entry.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                  }
                  if !entry.attachmentIDs.isEmpty {
                    Label("\(entry.attachmentIDs.count) photos", systemImage: "photo").font(
                      .caption
                    ).foregroundStyle(.secondary)
                  }
                }.padding(.vertical, 4)
              }
            }
            Button("Add entry", systemImage: "square.and.pencil") {
              Task { if let draft = await model.newDraft(projectID: projectID) { onEdit(draft) } }
            }.accessibilityIdentifier("add-entry")
          } header: {
            Text("FIELD NOTES")
          }
        }.navigationTitle(project.title).navigationBarTitleDisplayMode(.large)
          .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
              Button("Share report", systemImage: "square.and.arrow.up") {
                Task {
                  do {
                    sharing = ShareDocument(url: try await model.exportReport(projectID: projectID))
                  } catch { exportError = error.localizedDescription }
                }
              }
            }
          }
      } else {
        ContentUnavailableView(
          "Project unavailable", systemImage: "folder.badge.questionmark",
          description: Text("The workspace has not been changed."))
      }
    }.sheet(isPresented: $addingTask) { NewTaskView(projectID: projectID) }
      .sheet(item: $sharing) { ShareSheet(url: $0.url) }
      .alert(
        "Report couldn't be created",
        isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(exportError ?? "")
      }
  }
}

private struct NewTaskView: View {
  @EnvironmentObject private var model: WorkspaceModel
  let projectID: UUID
  @State private var editor: TaskEditorAppleFieldsHost?
  @State private var editorError: String?
  var body: some View {
    Group {
      if let editor {
        NewTaskNativeForm(editor: editor)
      } else {
        NavigationStack {
          Form {
            if let editorError {
              Section { Label(editorError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
          }.navigationTitle("New task").navigationBarTitleDisplayMode(.inline)
        }
      }
    }.onAppear { startEditor() }
      .onDisappear {
        try? editor?.close()
        editor = nil
      }
  }
  private func startEditor() {
    guard editor == nil else { return }
    do {
      editor = try TaskEditorAppleFieldsHost { title, responsible in
        if await model.addTask(projectID: projectID, title: title, responsible: responsible) { return .saved }
        return await .failed(model.saveError ?? "Task could not be saved. Your text has been kept.")
      }
      editorError = nil
    } catch { editorError = error.localizedDescription }
  }
}

private struct NewTaskNativeForm: View {
  @ObservedObject var editor: TaskEditorAppleFieldsHost
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    let form = editor.snapshot
    NavigationStack {
      Form {
        // Public rendering is deliberately limited to the exact shared fields
        // Section. The app keeps its native shell until that contract exists.
        TaskEditorNativeFields(owner: editor)
        if let error = editor.eventFailure ?? editor.adapterFailure ?? form.renderingFailure ?? node(form, "task.failure.message")?.properties["text"]?.string {
          Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        Section {
          Text(property(form, "task.disclosure.message", "text")).font(.footnote).foregroundStyle(.secondary)
        }
      }.navigationTitle(property(form, "task.screen", "title")).navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(property(form, "task.cancel", "label")) { send(form, "task.cancel", .activate) }
            .disabled(disabled(form, "task.cancel"))
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(property(form, "task.save", "label")) { send(form, "task.save", .activate) }
            .disabled(disabled(form, "task.save"))
        }
      }
    }.interactiveDismissDisabled(form.state.saving)
      .onChange(of: form.outcome) { _, outcome in
        if outcome == .saved || outcome == .cancelled { dismiss() }
      }
  }
  private func send(_ form: TaskEditorPresentationSnapshot, _ nodeID: String,
    _ event: UIEventKind, _ value: UIValue = .null)
  {
    guard let identity = form.render.identity(for: nodeID) else { return }
    editor.send(UIEventEnvelope(revision: form.render.document.revision,
      identity: identity, event: event, value: value))
  }
  private func node(_ form: TaskEditorPresentationSnapshot, _ id: String) -> UINode? {
    var pending = [form.render.document.root]
    while let value = pending.popLast() {
      if value.id == id { return value }
      pending.append(contentsOf: value.children)
    }
    return nil
  }
  private func property(_ form: TaskEditorPresentationSnapshot, _ id: String, _ key: String) -> String {
    node(form, id)?.properties[key]?.string ?? ""
  }
  private func disabled(_ form: TaskEditorPresentationSnapshot, _ id: String) -> Bool {
    editor.inputUnavailable || node(form, id)?.properties["disabled"]?.bool != false
  }
}

struct EntryDetail: View {
  let entry: LogEntry
  var body: some View {
    List {
      Section {
        Label(entry.category.rawValue.capitalized, systemImage: "tag").foregroundStyle(
          FieldStyle.green)
        Text(entry.occurredAt, format: .dateTime.year().month(.wide).day().hour().minute())
          .foregroundStyle(.secondary)
        if !entry.note.isEmpty { Text(entry.note).textSelection(.enabled) }
      }
      if !entry.attachmentIDs.isEmpty {
        Section("PHOTOS") { ForEach(entry.attachmentIDs, id: \.self) { PhotoPreview(id: $0) } }
      }
      Section {
        Label("Saved on this device", systemImage: "internaldrive").font(.footnote).foregroundStyle(
          .secondary)
      }
    }.navigationTitle(entry.title).navigationBarTitleDisplayMode(.inline)
  }
}
struct ShareDocument: Identifiable {
  let id = UUID()
  let url: URL
}
struct ShareSheet: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
