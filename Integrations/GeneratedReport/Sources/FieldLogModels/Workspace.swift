import Foundation

public enum FieldLogError: Error, LocalizedError, Equatable, Sendable {
  case validation(String)
  case missingRecord
  case unsupportedSchema(Int)
  case staleRevision
  case storage(String)
  public var errorDescription: String? {
    switch self {
    case .validation(let message), .storage(let message): message
    case .missingRecord: "This record is no longer available. Your changes have not been discarded."
    case .unsupportedSchema:
      "This workspace was created by another app version. Its files have been preserved."
    case .staleRevision:
      "A newer workspace revision exists. Reload before saving so no changes are overwritten."
    }
  }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var site: String
  public var createdAt: Date
  public init(id: UUID = UUID(), title: String, site: String = "", createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.site = site
    self.createdAt = createdAt
  }
}
public struct WorkTask: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var projectID: UUID
  public var title: String
  /// A local free-text responsibility label. It is not a verified team account.
  public var responsible: String
  public var completed: Bool
  public var position: Int
  public var updatedAt: Date
  public init(
    id: UUID = UUID(), projectID: UUID, title: String, responsible: String = "",
    completed: Bool = false, position: Int = 0, updatedAt: Date = Date()
  ) {
    self.id = id
    self.projectID = projectID
    self.title = title
    self.responsible = responsible
    self.completed = completed
    self.position = position
    self.updatedAt = updatedAt
  }
}
public enum EntryCategory: String, Codable, CaseIterable, Sendable {
  case observation, progress, issue, delivery
}
public struct Attachment: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var filename: String
  public var byteCount: Int
  public var createdAt: Date
  public init(id: UUID, byteCount: Int, createdAt: Date = Date()) {
    self.id = id
    filename = id.uuidString.lowercased() + ".jpg"
    self.byteCount = byteCount
    self.createdAt = createdAt
  }
}
public struct LogEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var projectID: UUID
  public var title: String
  public var note: String
  public var category: EntryCategory
  public var occurredAt: Date
  public var attachmentIDs: [UUID]
  public var savedAt: Date
}
public struct EntryDraft: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var projectID: UUID
  public var title: String
  public var note: String
  public var category: EntryCategory
  public var occurredAt: Date
  public var attachmentIDs: [UUID]
  public var updatedAt: Date
  public init(
    id: UUID = UUID(), projectID: UUID, title: String = "", note: String = "",
    category: EntryCategory = .observation, occurredAt: Date = Date(), attachmentIDs: [UUID] = [],
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.projectID = projectID
    self.title = title
    self.note = note
    self.category = category
    self.occurredAt = occurredAt
    self.attachmentIDs = attachmentIDs
    self.updatedAt = updatedAt
  }
}
public struct PendingChange: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case projectCreated, taskSaved, taskOrderChanged, entrySaved
  }
  public var id: UUID
  public var kind: Kind
  public var recordID: UUID
  public var revision: UInt64
  public var createdAt: Date
  /// Stable idempotency key for a future backend. Nothing is sent by this build.
  public var idempotencyKey: String { id.uuidString.lowercased() }
}
public struct Restoration: Codable, Equatable, Sendable {
  public var selectedProjectID: UUID?
  public var openDraftID: UUID?
  public init(selectedProjectID: UUID? = nil, openDraftID: UUID? = nil) {
    self.selectedProjectID = selectedProjectID
    self.openDraftID = openDraftID
  }
}
public struct Workspace: Codable, Equatable, Sendable {
  public var schema: Int = 1
  public var id: UUID
  public var revision: UInt64 = 0
  public var createdAt: Date
  public var projects: [Project] = []
  public var tasks: [WorkTask] = []
  public var entries: [LogEntry] = []
  public var drafts: [EntryDraft] = []
  public var attachments: [Attachment] = []
  public var outbox: [PendingChange] = []
  public var restoration = Restoration()
  public init(id: UUID = UUID(), createdAt: Date = Date()) {
    self.id = id
    self.createdAt = createdAt
  }

  public func validate() throws {
    guard schema == 1 else { throw FieldLogError.unsupportedSchema(schema) }
    guard projects.count <= 1000, tasks.count <= 10000, entries.count <= 10000,
      drafts.count <= 1000, attachments.count <= 10000, outbox.count <= 50000
    else {
      throw FieldLogError.validation(
        "This local workspace has reached its storage limit. Export your work before adding more records."
      )
    }
    func unique<T>(_ values: [T], _ key: (T) -> UUID) throws {
      guard Set(values.map(key)).count == values.count else {
        throw FieldLogError.validation("Duplicate record identifiers in saved workspace.")
      }
    }
    try unique(projects, \.id)
    try unique(tasks, \.id)
    try unique(entries, \.id)
    try unique(drafts, \.id)
    try unique(attachments, \.id)
    try unique(outbox, \.id)
    let projectIDs = Set(projects.map(\.id))
    let attachmentIDs = Set(attachments.map(\.id))
    for project in projects {
      try Self.text(project.title, label: "Project name", maximum: 160, required: true)
      try Self.text(project.site, label: "Site", maximum: 500)
    }
    for task in tasks {
      guard projectIDs.contains(task.projectID), task.position >= 0 else {
        throw FieldLogError.missingRecord
      }
      try Self.text(task.title, label: "Task", maximum: 240, required: true)
      try Self.text(task.responsible, label: "Responsible person", maximum: 160)
    }
    for entry in entries {
      guard projectIDs.contains(entry.projectID),
        Set(entry.attachmentIDs).isSubset(of: attachmentIDs),
        Set(entry.attachmentIDs).count == entry.attachmentIDs.count, entry.attachmentIDs.count <= 8
      else { throw FieldLogError.missingRecord }
      try Self.text(entry.title, label: "Entry title", maximum: 160, required: true)
      try Self.text(entry.note, label: "Note", maximum: 100000)
    }
    for draft in drafts {
      guard projectIDs.contains(draft.projectID),
        Set(draft.attachmentIDs).isSubset(of: attachmentIDs),
        Set(draft.attachmentIDs).count == draft.attachmentIDs.count, draft.attachmentIDs.count <= 8
      else { throw FieldLogError.missingRecord }
      try Self.text(draft.title, label: "Draft title", maximum: 160)
      try Self.text(draft.note, label: "Draft note", maximum: 100000)
    }
    for attachment in attachments {
      guard attachment.filename == attachment.id.uuidString.lowercased() + ".jpg",
        (1...6_291_456).contains(attachment.byteCount)
      else { throw FieldLogError.validation("Invalid local photo reference.") }
    }
    for operation in outbox {
      guard operation.revision <= revision else {
        throw FieldLogError.validation("Invalid pending revision.")
      }
    }
    if let selected = restoration.selectedProjectID, !projectIDs.contains(selected) {
      throw FieldLogError.missingRecord
    }
    if let draft = restoration.openDraftID, !drafts.contains(where: { $0.id == draft }) {
      throw FieldLogError.missingRecord
    }
  }
  public static func text(_ value: String, label: String, maximum: Int, required: Bool = false)
    throws
  {
    guard value.utf8.count <= maximum else {
      throw FieldLogError.validation("\(label) is too long (maximum \(maximum) UTF-8 bytes).")
    }
    guard !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FieldLogError.validation("\(label) can't be empty.")
    }
    guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
      throw FieldLogError.validation("\(label) contains an unsupported character.")
    }
  }
  public func matchingProjects(_ query: String) -> [Project] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return projects.filter {
      q.isEmpty || $0.title.localizedStandardContains(q) || $0.site.localizedStandardContains(q)
    }.sorted { $0.createdAt > $1.createdAt }
  }
  public func tasks(for projectID: UUID) -> [WorkTask] {
    tasks.filter { $0.projectID == projectID }.sorted {
      $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position
    }
  }
  public func progress(for projectID: UUID) -> Double {
    let items = tasks(for: projectID)
    return items.isEmpty ? 0 : Double(items.filter(\.completed).count) / Double(items.count)
  }
  public func entries(for projectID: UUID) -> [LogEntry] {
    entries.filter { $0.projectID == projectID }.sorted { $0.occurredAt > $1.occurredAt }
  }
  private mutating func enqueue(_ kind: PendingChange.Kind, _ record: UUID, now: Date) throws {
    guard revision < UInt64.max else {
      throw FieldLogError.validation("Workspace revision limit reached.")
    }
    outbox.append(
      PendingChange(
        id: UUID(), kind: kind, recordID: record, revision: revision + 1, createdAt: now))
  }

  @discardableResult public mutating func createProject(
    id: UUID = UUID(), title: String, site: String, now: Date = Date()
  ) throws -> UUID {
    try Self.text(title, label: "Project name", maximum: 160, required: true)
    try Self.text(site, label: "Site", maximum: 500)
    let project = Project(
      id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), site: site,
      createdAt: now)
    projects.append(project)
    restoration.selectedProjectID = project.id
    try enqueue(.projectCreated, project.id, now: now)
    return project.id
  }
  public mutating func saveTask(
    projectID: UUID, title: String, responsible: String, now: Date = Date()
  ) throws {
    guard projects.contains(where: { $0.id == projectID }) else {
      throw FieldLogError.missingRecord
    }
    try Self.text(title, label: "Task", maximum: 240, required: true)
    try Self.text(responsible, label: "Responsible person", maximum: 160)
    let task = WorkTask(
      projectID: projectID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      responsible: responsible, position: tasks(for: projectID).count, updatedAt: now)
    tasks.append(task)
    try enqueue(.taskSaved, task.id, now: now)
  }
  public mutating func toggleTask(_ id: UUID, now: Date = Date()) throws {
    guard let i = tasks.firstIndex(where: { $0.id == id }) else {
      throw FieldLogError.missingRecord
    }
    tasks[i].completed.toggle()
    tasks[i].updatedAt = now
    try enqueue(.taskSaved, id, now: now)
  }
  public mutating func reorderTasks(projectID: UUID, ids: [UUID], now: Date = Date()) throws {
    let current = tasks(for: projectID)
    guard ids.count == current.count, Set(ids) == Set(current.map(\.id)) else {
      throw FieldLogError.validation("Task order must include each task exactly once.")
    }
    for (position, id) in ids.enumerated() {
      guard let index = tasks.firstIndex(where: { $0.id == id }) else {
        throw FieldLogError.missingRecord
      }
      tasks[index].position = position
      tasks[index].updatedAt = now
    }
    try enqueue(.taskOrderChanged, projectID, now: now)
  }
  public mutating func saveDraft(_ draft: EntryDraft) throws {
    guard projects.contains(where: { $0.id == draft.projectID }) else {
      throw FieldLogError.missingRecord
    }
    try Self.text(draft.title, label: "Draft title", maximum: 160)
    try Self.text(draft.note, label: "Draft note", maximum: 100000)
    if let i = drafts.firstIndex(where: { $0.id == draft.id }) {
      var merged = draft
      merged.attachmentIDs =
        drafts[i].attachmentIDs
        + draft.attachmentIDs.filter { !drafts[i].attachmentIDs.contains($0) }
      drafts[i] = merged
    } else {
      drafts.append(draft)
    }
  }
  public mutating func commitDraft(_ id: UUID, now: Date = Date()) throws {
    guard let draft = drafts.first(where: { $0.id == id }) else {
      throw FieldLogError.missingRecord
    }
    try Self.text(draft.title, label: "Entry title", maximum: 160, required: true)
    // The draft identity becomes the saved entry identity. A repeated commit
    // cannot append a duplicate entry or outbox operation.
    guard !entries.contains(where: { $0.id == id }) else {
      throw FieldLogError.validation("This draft has already been saved.")
    }
    entries.append(
      LogEntry(
        id: id, projectID: draft.projectID,
        title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), note: draft.note,
        category: draft.category, occurredAt: draft.occurredAt, attachmentIDs: draft.attachmentIDs,
        savedAt: now))
    drafts.removeAll { $0.id == id }
    if restoration.openDraftID == id { restoration.openDraftID = nil }
    try enqueue(.entrySaved, id, now: now)
  }
  public func report(projectID: UUID) throws -> String {
    guard let project = projects.first(where: { $0.id == projectID }) else {
      throw FieldLogError.missingRecord
    }
    let formatter = ISO8601DateFormatter()
    var lines = [
      "FIELDLOG · PROJECT REPORT", project.title, project.site, "",
      "Offline workspace · local records only", "No upload or team synchronization is implied.", "",
      "TASKS",
    ]
    for task in tasks(for: projectID) {
      lines.append(
        "\(task.completed ? "[x]":"[ ]") \(task.title)\(task.responsible.isEmpty ? "":" — "+task.responsible)"
      )
    }
    lines.append(contentsOf: ["", "ENTRIES"])
    for entry in entries(for: projectID) {
      lines.append(contentsOf: [
        "\(formatter.string(from:entry.occurredAt)) · \(entry.category.rawValue.uppercased())",
        entry.title, entry.note,
        "Photos: \(entry.attachmentIDs.count) (not embedded in this text report)", "",
      ])
    }
    return lines.joined(separator: "\n")
  }
}
