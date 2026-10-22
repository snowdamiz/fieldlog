import FieldLogModels
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
  @Environment(\.dismiss) private var dismiss
  let projectID: UUID
  @State private var title = ""
  @State private var responsible = ""
  @State private var saving = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Task") {
          TextField("What needs to happen?", text: $title, axis: .vertical).accessibilityIdentifier(
            "task-title")
          TextField("Responsible person (optional)", text: $responsible)
        }
        if let error = model.saveError {
          Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        Section {
          Text(
            "A responsibility label is stored locally. It does not invite or notify another person."
          ).font(.footnote).foregroundStyle(.secondary)
        }
      }.navigationTitle("New task").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            saving = true
            Task {
              if await model.addTask(projectID: projectID, title: title, responsible: responsible) {
                dismiss()
              }
              saving = false
            }
          }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
        }
      }
    }.interactiveDismissDisabled(saving)
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
