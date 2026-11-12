import Foundation
import MixerCore
import MixerUI
import MixerAndroid

private typealias PhotoCall = @convention(c) @Sendable (Int64, UnsafePointer<UInt8>?, Int) -> Int32
private typealias SurfaceCall = @convention(c) @Sendable (Int64, Int32, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int) -> Int32
@MainActor private final class BridgeSurface: AndroidUINativeSurface {
    let context: Int64
    let callback: SurfaceCall
    var failure = false
    let profile = AndroidUIProfile.measuredMultilineLongNotesV4
    var capabilities: AndroidUICapabilities { profile.capabilities }
    init(_ context: Int64, _ callback: @escaping SurfaceCall) { self.context = context; self.callback = callback }
    func call(_ operation: Int32, _ owner: UUID, _ packet: Data = Data(), _ appearance: Data = Data()) throws {
        guard !failure else { throw PublicHostError.surface }
        let owner = Data(owner.uuidString.utf8)
        let status = owner.withUnsafeBytes { o in packet.withUnsafeBytes { p in appearance.withUnsafeBytes { a in
            callback(context, operation, o.bindMemory(to: UInt8.self).baseAddress, o.count,
                p.bindMemory(to: UInt8.self).baseAddress, p.count, a.bindMemory(to: UInt8.self).baseAddress, a.count)
        } } }
        guard status == 0 else { failure = true; throw PublicHostError.surface }
    }
    func activate(owner: UUID) throws { try call(0, owner) }
    func install(_ frame: AndroidUIFrame) throws {
        guard frame.profile == profile else { throw PublicHostError.profile }
        try call(1, frame.owner, frame.packet, frame.appearanceDescriptorV2)
    }
    func revoke(owner: UUID) {
        // Cleanup must still run after a rejected install. Preserve any earlier
        // failure and never report a failed native lifetime as accepted.
        let previous = failure; failure = false
        do { try call(2, owner) } catch { failure = true }
        failure = failure || previous
    }
}
private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64: Int32] = [:]
    func reserve(_ id: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[id] == nil, values.count < 16 else { return false }; values[id] = 0; return true
    }
    func complete(_ id: Int64, _ result: Int32) { lock.lock(); defer { lock.unlock() }; values[id] = result }
    func take(_ id: Int64) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let result = values[id] else { return -1 }
        if result != 0 { values.removeValue(forKey: id) }; return result
    }
}
private let replies = Replies()
@MainActor private enum Applications {
    static var values: [Int64: (PublicAndroidApplication, BridgeSurface)] = [:]
    static func report(_ id: Int64, _ token: Data, _ result: Int32,
        _ callback: @escaping @convention(c) @Sendable (Int64, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, Int, Int32) -> Int32) async -> Int32 {
        guard let (app, surface) = values[id], !surface.failure else { return 2 }
        if result == -1 {
            guard let request = app.presentation.takeReportRequest() else { return 1 }
            let idBytes = Data(request.id.uuidString.utf8)
            let path = Data(request.fileURL.path.utf8)
            guard path.count <= 4096 else { _ = app.presentation.completeReport(requestID: request.id, result: .unavailable); return 1 }
            let status = idBytes.withUnsafeBytes { t in path.withUnsafeBytes { b in
                callback(id, t.bindMemory(to: UInt8.self).baseAddress, t.count,
                    b.bindMemory(to: UInt8.self).baseAddress, b.count, request.byteCount, request.descriptor)
            } }
            if status != 0 { _ = app.presentation.completeReport(requestID: request.id, result: .unavailable) }
        } else {
            guard let text = String(data: token, encoding: .utf8), let uuid = UUID(uuidString: text),
                Data(uuid.uuidString.utf8) == token else { return 2 }
            let value: ReportShareResult = result == 0 ? .closed : result == 1 ? .opened : .unavailable
            _ = app.presentation.completeReport(requestID: uuid, result: value)
        }
        do { try await app.settle(); return 1 } catch { return 2 }
    }
    static func photo(_ id: Int64, _ request: Data, _ result: Int32, _ jpeg: Data, _ callback: @escaping PhotoCall) async -> Int32 {
        guard let (app, surface) = values[id], !surface.failure else { return 2 }
        if result == -1 {
            guard let request = app.presentation.takePhotoRequest() else { return 1 }
            let data = Data(request.id.uuidString.utf8)
            return data.withUnsafeBytes { callback(id, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) == 0 ? 1 : 2 }
        }
        guard let text = String(data: request, encoding: .utf8), let token = UUID(uuidString: text),
            Data(token.uuidString.utf8) == request else { return 2 }
        let value: PhotoSelectionResult
        switch result {
        case 0: value = .cancelled
        case 1: value = .failed(.denied)
        case 2: value = .failed(.invalid)
        case 3: value = .failed(.tooLarge)
        case 4: value = .failed(.unavailable)
        case 5: value = .jpeg(jpeg)
        default: return 2
        }
        // A stale/duplicate result is an ordinary rejected service completion.
        _ = await app.presentation.completePhoto(requestID: token, result: value)
        do { try await app.settle(); return 1 } catch { return 2 }
    }
    static func execute(_ id: Int64, _ operation: Int32, _ profile: String, _ directory: Data, _ owner: Data, _ event: Data, _ callback: @escaping SurfaceCall) async -> Int32 {
        do {
            switch operation {
            case 0:
                guard values[id] == nil, values.count < 16 else { throw PublicHostError.context }
                let surface = BridgeSurface(id, callback)
                guard let path = String(data: directory, encoding: .utf8), path.hasPrefix("/"), !path.utf8.contains(0) else { throw PublicHostError.storage }
                let application = try await PublicAndroidApplication(surface: surface, selectedProfile: profile, directory: URL(fileURLWithPath: path, isDirectory: true))
                values[id] = (application, surface)
            case 1:
                guard let (application, surface) = values[id], !surface.failure,
                      let text = String(data: owner, encoding: .utf8), let token = UUID(uuidString: text),
                      Data(token.uuidString.utf8) == owner else { throw PublicHostError.context }
                // Array payload opts into atomic batch admission; scalar ABI
                // clients retain the existing strict single-event path.
                if event.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
                    try application.sendBatch(owner: token, originalEnvelopes: event)
                } else {
                    try application.send(owner: token, originalEnvelope: event)
                }
                try await application.settle()
            case 2:
                guard let (application, surface) = values[id] else { throw PublicHostError.context }
                await application.close()
                guard !surface.failure else { throw PublicHostError.surface }
                values.removeValue(forKey: id)
            default: throw PublicHostError.context
            }
            return 1
        } catch { return 2 }
    }
}
@_cdecl("mixer_public_android_submit")
public func publicAndroidSubmit(_ context: Int64, _ operation: Int32,
    _ profile: UnsafePointer<UInt8>?, _ profileCount: Int,
    _ directory: UnsafePointer<UInt8>?, _ directoryCount: Int,
    _ owner: UnsafePointer<UInt8>?, _ ownerCount: Int,
    _ event: UnsafePointer<UInt8>?, _ eventCount: Int,
    _ callback: @convention(c) @Sendable @escaping (Int64, Int32, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int) -> Int32) -> Int32 {
    guard context > 0, (0...2).contains(operation), (0...64).contains(profileCount),
          (0...4096).contains(directoryCount), (operation == 0 ? directoryCount > 0 : directoryCount == 0),
          (directoryCount == 0 || directory != nil), (0...64).contains(ownerCount), (0...1_048_576).contains(eventCount),
          (profileCount == 0 || profile != nil), (ownerCount == 0 || owner != nil), (eventCount == 0 || event != nil) else { return 1 }
    let profile = profile.map { Data(bytes: $0, count: profileCount) } ?? Data()
    let directory = directory.map { Data(bytes: $0, count: directoryCount) } ?? Data()
    let owner = owner.map { Data(bytes: $0, count: ownerCount) } ?? Data()
    let event = event.map { Data(bytes: $0, count: eventCount) } ?? Data()
    guard let selected = String(data: profile, encoding: .utf8), replies.reserve(context) else { return 1 }
    Task { @MainActor in replies.complete(context, await Applications.execute(context, operation, selected, directory, owner, event, callback)) }
    return 0
}
@_cdecl("mixer_public_android_poll")
public func publicAndroidPoll(_ context: Int64) -> Int32 {
    guard Thread.isMainThread else { return -1 }
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    return replies.take(context)
}

// Separate app-owned service ABI. The existing public UI submit ABI is unchanged.
@_cdecl("fieldlog_android_photo_submit")
public func fieldlogAndroidPhotoSubmit(_ context: Int64, _ request: UnsafePointer<UInt8>?, _ requestCount: Int,
    _ result: Int32, _ jpeg: UnsafePointer<UInt8>?, _ jpegCount: Int,
    _ callback: @convention(c) @Sendable @escaping (Int64, UnsafePointer<UInt8>?, Int) -> Int32) -> Int32 {
    guard context > 0, (-1...5).contains(result),
        requestCount == (result == -1 ? 0 : 36), (requestCount == 0 || request != nil),
        (0...6_291_456).contains(jpegCount), (jpegCount == 0 || jpeg != nil),
        (result == 5 ? jpegCount >= 3 : jpegCount == 0), replies.reserve(context) else { return 1 }
    let request = request.map { Data(bytes: $0, count: requestCount) } ?? Data()
    let data = jpeg.map { Data(bytes: $0, count: jpegCount) } ?? Data()
    Task { @MainActor in replies.complete(context, await Applications.photo(context, request, result, data, callback)) }
    return 0
}

// App attachment extension; original public UI submit and photo ABIs stay intact.
@_cdecl("fieldlog_android_report_submit")
public func fieldlogAndroidReportSubmit(_ context: Int64, _ token: UnsafePointer<UInt8>?, _ count: Int,
    _ result: Int32,
    _ callback: @convention(c) @Sendable @escaping (Int64, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, Int, Int32) -> Int32) -> Int32 {
    guard context > 0, (-1...2).contains(result), count == (result == -1 ? 0 : 36),
        (count == 0 || token != nil), replies.reserve(context) else { return 1 }
    let request = token.map { Data(bytes: $0, count: count) } ?? Data()
    Task { @MainActor in replies.complete(context, await Applications.report(context, request, result, callback)) }
    return 0
}
