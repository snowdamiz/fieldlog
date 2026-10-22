import FieldLogModels
import SwiftUI

struct WorkspaceView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @State private var projectPath: [UUID] = []
  @State private var addingProject = false
  @State private var editingDraft: EntryDraft?
  @State private var restored = false
  var body: some View {
    Group {
      if model.loading {
        ProgressView("Opening your workspace…")
      } else if let error = model.openError {
        ContentUnavailableView {
          Label("Workspace couldn't open", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
          Text(error)
        } actions: {
          Button("Try again") { Task { await model.retryOpen() } }
        }
      } else if let workspace = model.workspace {
        TabView {
          NavigationStack(path: $projectPath) {
            ProjectList(
              workspace: workspace, testing: model.isTestWorkspace, onAdd: { addingProject = true }
            )
            .navigationDestination(for: UUID.self) { id in
              ProjectDetail(projectID: id, onEdit: { editingDraft = $0 })
            }
          }.tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
          NavigationStack {
            DeviceQueue(
              workspace: workspace,
              onEdit: { draft in
                model.openDraft(draft.id)
                editingDraft = draft
              })
          }.tabItem { Label("On device", systemImage: "internaldrive") }
          NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear {
          guard !restored else { return }
          restored = true
          if let id = workspace.restoration.selectedProjectID { projectPath = [id] }
          if let id = workspace.restoration.openDraftID {
            editingDraft = workspace.drafts.first { $0.id == id }
          }
        }
        .onChange(of: projectPath) { _, path in model.restoreProject(path.last) }
        .safeAreaInset(edge: .top, spacing: 0) {
          if let error = model.saveError {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote)
              .foregroundStyle(.white).padding(10).frame(maxWidth: .infinity).background(.red)
          }
        }
      }
    }
    .sheet(isPresented: $addingProject) {
      NewProjectView { title, site in
        if let id = await model.createProject(title: title, site: site) {
          projectPath = [id]
          return true
        }
        return false
      }
    }
    .sheet(item: $editingDraft, onDismiss: { model.closeDraft() }) { draft in
      EntryEditor(draft: draft)
    }
  }
}

private struct ProjectList: View {
  let workspace: Workspace
  let testing: Bool
  let onAdd: () -> Void
  @State private var search = ""
  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          Label("OFFLINE WORKSPACE", systemImage: "circle.inset.filled").font(
            .caption.weight(.semibold)
          ).foregroundStyle(FieldStyle.green)
          if testing {
            Text("Isolated test workspace").font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("test-workspace-badge")
          }
          Text("A clear record\nof the work.").font(.largeTitle.weight(.semibold))
          Text("Projects, checklists and field notes. Saved on this device.").font(.subheadline)
            .foregroundStyle(.secondary)
        }.padding(.vertical, 12)
      }.listRowBackground(Color.clear).listRowSeparator(.hidden)
      if workspace.projects.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "folder.badge.plus").font(.system(size: 34)).foregroundStyle(
              FieldStyle.green)
            Text("Start with one project").font(.title3.weight(.semibold))
            Text("Name a job or a site, then keep the details together as work happens.")
              .foregroundStyle(.secondary)
            Button("Create your first project", action: onAdd).buttonStyle(.borderedProminent)
              .tint(FieldStyle.filledButton).foregroundStyle(.white)
              .accessibilityIdentifier("create-first-project")
          }.padding(.vertical, 16)
        }
      } else {
        Section("\(workspace.projects.count) PROJECT\(workspace.projects.count==1 ? "":"S")") {
          ForEach(workspace.matchingProjects(search)) { project in
            NavigationLink(value: project.id) {
              VStack(alignment: .leading, spacing: 9) {
                Text(project.title).font(.headline)
                if !project.site.isEmpty {
                  Label(project.site, systemImage: "mappin").font(.subheadline).foregroundStyle(
                    .secondary)
                }
                HStack {
                  let tasks = workspace.tasks(for: project.id)
                  Label(
                    "\(tasks.filter(\.completed).count)/\(tasks.count) tasks",
                    systemImage: "checkmark.circle")
                  Spacer()
                  Text("\(workspace.entries(for:project.id).count) entries")
                }.font(.caption).foregroundStyle(.secondary)
                ProgressView(value: workspace.progress(for: project.id)).tint(FieldStyle.green)
              }.padding(.vertical, 6)
            }
          }
          if workspace.matchingProjects(search).isEmpty {
            ContentUnavailableView.search(text: search)
          }
        }
      }
    }.scrollContentBackground(.hidden).background(FieldStyle.paper).navigationTitle("FieldLog")
      .searchable(text: $search, prompt: "Search projects or sites")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("New project", systemImage: "plus", action: onAdd)
        }
      }
  }
}

struct NewProjectView: View {
  let save: (String, String) async -> Bool
  @EnvironmentObject private var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var site = ""
  @State private var saving = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Project") {
          TextField("Project name", text: $title).textInputAutocapitalization(.words)
            .accessibilityIdentifier("project-name")
          TextField("Site or location (optional)", text: $site).textInputAutocapitalization(.words)
        }
        if let error = model.saveError {
          Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        Section {
          Label("Stored on this device", systemImage: "internaldrive")
          Text(
            "No account is needed for an offline workspace. Cloud sync is not connected in this build."
          ).font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("New project").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            saving = true
            Task {
              if await save(title, site) { dismiss() }
              saving = false
            }
          }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            .accessibilityIdentifier("save-project")
        }
      }
    }.interactiveDismissDisabled(saving)
  }
}

private struct DeviceQueue: View {
  let workspace: Workspace
  let onEdit: (EntryDraft) -> Void
  var body: some View {
    List {
      Section {
        Label("Your records are saved locally", systemImage: "internaldrive.fill").font(.headline)
          .foregroundStyle(FieldStyle.green)
        Text("Cloud sync isn't connected. Nothing in this queue has been sent to a server.")
          .foregroundStyle(.secondary)
      }
      if !workspace.drafts.isEmpty {
        Section("DRAFTS") {
          ForEach(workspace.drafts.sorted { $0.updatedAt > $1.updatedAt }) { draft in
            Button {
              onEdit(draft)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(draft.title.isEmpty ? "Untitled entry" : draft.title).foregroundStyle(.primary)
                Text(workspace.projects.first { $0.id == draft.projectID }?.title ?? "Project")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      Section("\(workspace.outbox.count) PENDING CHANGE\(workspace.outbox.count==1 ? "":"S")") {
        if workspace.outbox.isEmpty {
          Text("Changes you make will appear here.").foregroundStyle(.secondary)
        }
        ForEach(workspace.outbox.reversed()) { item in
          VStack(alignment: .leading, spacing: 4) {
            Text(label(item.kind))
            Text(item.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
            Label("Saved on device · not sent", systemImage: "clock").font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }.navigationTitle("On device")
  }
  private func label(_ kind: PendingChange.Kind) -> String {
    switch kind {
    case .projectCreated: "Project created"
    case .taskSaved: "Task updated"
    case .taskOrderChanged: "Checklist reordered"
    case .entrySaved: "Entry saved"
    }
  }
}

private struct SettingsView: View {
  var body: some View {
    Form {
      Section("WORKSPACE") {
        Label("Offline mode", systemImage: "internaldrive")
        Text(
          "No account is signed in. Projects, notes and selected photos stay in this app's private storage. Deleting the app deletes local records; export reports before removing it."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section("THIS BUILD") {
        LabeledContent("Version", value: "0.1.0 · Native baseline")
        Text(
          "Sign-in, team sync, camera capture, notifications, maps and purchases are not connected yet. No remote success is simulated."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section("PRIVACY") {
        Text(
          "This baseline sends no analytics or user content. Photo library selection is handled by the system picker. Reports are shared only when you choose a destination in the system share sheet."
        ).font(.footnote)
      }
    }.navigationTitle("Settings")
  }
}
