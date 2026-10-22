import FieldLogModels
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private func closeDescriptor(_ fd: Int32) {
  #if canImport(Darwin)
    _ = Darwin.close(fd)
  #elseif canImport(Glibc)
    _ = Glibc.close(fd)
  #endif
}

/// One private on-device workspace. All state mutations and their pending
/// outbox records commit in a single fsynced atomic snapshot.
public actor WorkspaceRepository {
  public typealias Fault = @Sendable (String) throws -> Void
  private let directory: URL
  private var lockFD: Int32
  private let fault: Fault?
  private var workspace: Workspace
  private var unavailable = false
  private static let maximumSnapshotBytes = 32 * 1024 * 1024

  public init(directory: URL, fault: Fault? = nil) throws {
    self.directory = directory
    self.fault = fault
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    lockFD = open(directory.appendingPathComponent("workspace.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else { throw FieldLogError.storage("Workspace lock could not open.") }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      closeDescriptor(lockFD)
      throw FieldLogError.storage(
        "This workspace is open in another process. Close it before continuing.")
    }
    do {
      let file = directory.appendingPathComponent("workspace.json")
      if FileManager.default.fileExists(atPath: file.path) {
        workspace = try Self.read(file)
      } else {
        workspace = Workspace()
        try Self.write(workspace, to: file, fault: fault)
      }
    } catch {
      flock(lockFD, LOCK_UN)
      closeDescriptor(lockFD)
      throw error
    }
  }
  deinit {
    if lockFD >= 0 {
      flock(lockFD, LOCK_UN)
      closeDescriptor(lockFD)
    }
  }
  public func close() {
    unavailable = true
    if lockFD >= 0 {
      flock(lockFD, LOCK_UN)
      closeDescriptor(lockFD)
      lockFD = -1
    }
  }
  public func snapshot() -> Workspace { workspace }

  @discardableResult public func transact(
    expectedRevision: UInt64? = nil, _ mutation: @Sendable (inout Workspace) throws -> Void
  ) throws -> Workspace {
    guard !unavailable else {
      throw FieldLogError.storage(
        "A storage commit was interrupted. Reopen the app before saving again; existing files have been preserved."
      )
    }
    if let expectedRevision, expectedRevision != workspace.revision {
      throw FieldLogError.staleRevision
    }
    guard workspace.revision < UInt64.max else {
      throw FieldLogError.storage(
        "Workspace revision limit reached. Export your records before continuing.")
    }
    // Prevent an externally replaced snapshot from being silently overwritten.
    let file = directory.appendingPathComponent("workspace.json")
    let current = try Self.read(file)
    guard current == workspace else { throw FieldLogError.staleRevision }
    var next = workspace
    try mutation(&next)
    next.revision = workspace.revision + 1
    try next.validate()
    do { try Self.write(next, to: file, fault: fault) } catch {
      unavailable = true
      throw error
    }
    workspace = next
    return workspace
  }
  public func addPhoto(jpeg: Data, to draftID: UUID, now: Date = Date()) throws -> Workspace {
    guard (1...6_291_456).contains(jpeg.count), jpeg.starts(with: [0xff, 0xd8, 0xff]) else {
      throw FieldLogError.validation("Choose a JPEG photo up to 6 MiB.")
    }
    guard let draft = workspace.drafts.first(where: { $0.id == draftID }),
      draft.attachmentIDs.count < 8
    else { throw FieldLogError.validation("An entry can contain up to eight photos.") }
    let attachment = Attachment(id: UUID(), byteCount: jpeg.count, createdAt: now)
    let folder = directory.appendingPathComponent("photos", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Self.atomic(jpeg, to: folder.appendingPathComponent(attachment.filename), fault: fault)
    return try transact { next in
      guard let i = next.drafts.firstIndex(where: { $0.id == draftID }) else {
        throw FieldLogError.missingRecord
      }
      next.attachments.append(attachment)
      next.drafts[i].attachmentIDs.append(attachment.id)
      next.drafts[i].updatedAt = now
    }
  }
  public func photoURL(_ id: UUID) throws -> URL {
    guard let record = workspace.attachments.first(where: { $0.id == id }),
      record.filename == id.uuidString.lowercased() + ".jpg"
    else { throw FieldLogError.missingRecord }
    let file = directory.appendingPathComponent("photos").appendingPathComponent(record.filename)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard (attributes[.size] as? NSNumber)?.intValue == record.byteCount else {
      throw FieldLogError.storage(
        "This photo is missing or damaged. Its record has been preserved.")
    }
    return file
  }
  public func exportReport(projectID: UUID) throws -> URL {
    let text = try workspace.report(projectID: projectID)
    let folder = directory.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = folder.appendingPathComponent(
      "FieldLog-\(projectID.uuidString.lowercased())-r\(workspace.revision).txt")
    try Self.atomic(Data(text.utf8), to: file, fault: nil)
    return file
  }
  private static func read(_ file: URL) throws -> Workspace {
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    guard let size = attrs[.size] as? NSNumber, size.intValue > 0,
      size.intValue <= maximumSnapshotBytes
    else {
      throw FieldLogError.storage(
        "Saved workspace exceeds the supported size. Its file was not changed.")
    }
    let data = try Data(contentsOf: file)
    let state: Workspace
    do { state = try JSONDecoder().decode(Workspace.self, from: data) } catch {
      throw FieldLogError.storage(
        "Saved workspace could not be read. It has not been reset or overwritten.")
    }
    try state.validate()
    return state
  }
  private static func write(_ workspace: Workspace, to file: URL, fault: Fault?) throws {
    try workspace.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(workspace)
    guard data.count <= maximumSnapshotBytes else {
      throw FieldLogError.storage("Workspace is full. Export your records before adding more.")
    }
    try atomic(data, to: file, fault: fault)
  }
  private static func atomic(_ data: Data, to file: URL, fault: Fault?) throws {
    let folder = file.deletingLastPathComponent()
    let temporary = folder.appendingPathComponent(".saving-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try fault?("before_write")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw FieldLogError.storage("Temporary workspace file could not be created.") }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: data)
      try fault?("before_file_sync")
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try fault?("before_rename")
    guard rename(temporary.path, file.path) == 0 else {
      throw FieldLogError.storage(
        "Workspace could not be committed. Existing files have been preserved.")
    }
    try fault?("after_rename")
    let fd = open(folder.path, O_RDONLY)
    guard fd >= 0 else { throw FieldLogError.storage("Workspace directory could not be flushed.") }
    defer { closeDescriptor(fd) }
    guard fsync(fd) == 0 else {
      throw FieldLogError.storage("Workspace directory could not be flushed.")
    }
    try fault?("after_directory_sync")
  }
}
