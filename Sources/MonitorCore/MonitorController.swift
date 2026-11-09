import Foundation
import DDCBridge

public struct Monitor: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let audioUID: String
    public let volume: UInt16
    public let maxVolume: UInt16
}

public enum MonitorControllerError: Error, LocalizedError {
    case bridge(String)
    public var errorDescription: String? { if case .bridge(let message) = self { return message }; return nil }
}

public final class MonitorController: @unchecked Sendable {
    private let operationLock = NSLock()
    public init() {}
    private func message(_ p: UnsafePointer<CChar>) -> String { String(cString: p) }
    public func discover() throws -> [Monitor] {
        operationLock.lock(); defer { operationLock.unlock() }
        var records = [DDCMonitor](repeating: DDCMonitor(), count: 16); var count = 0
        var error = [CChar](repeating: 0, count: 512)
        let ok = records.withUnsafeMutableBufferPointer { b in
            ddc_discover(b.baseAddress, b.count, &count, &error, error.count)
        }
        guard ok != 0 else { throw MonitorControllerError.bridge(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        return records.prefix(count).map { r in
            Monitor(id: withUnsafePointer(to: r.id) { $0.withMemoryRebound(to: CChar.self, capacity: 96) { message($0) } },
                    name: withUnsafePointer(to: r.name) { $0.withMemoryRebound(to: CChar.self, capacity: 128) { message($0) } },
                    audioUID: withUnsafePointer(to: r.audio_uid) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { message($0) } },
                    volume: r.current, maxVolume: r.maximum)
        }
    }
    public func getVolume(id: String) throws -> (volume: UInt16, maxVolume: UInt16) {
        operationLock.lock(); defer { operationLock.unlock() }
        var current: UInt16 = 0, maximum: UInt16 = 0; var error = [CChar](repeating: 0, count: 512)
        let ok = id.withCString { ddc_get_volume($0, &current, &maximum, &error, error.count) }
        guard ok != 0 else { throw MonitorControllerError.bridge(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        return (current, maximum)
    }
    public func setVolume(id: String, value: UInt16) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        var error = [CChar](repeating: 0, count: 512)
        let ok = id.withCString { ddc_set_volume($0, value, &error, error.count) }
        guard ok != 0 else { throw MonitorControllerError.bridge(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
    }
    public func mute(id: String, _ muted: Bool) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        var error = [CChar](repeating: 0, count: 512)
        let ok = id.withCString { ddc_set_mute($0, muted ? 1 : 0, &error, error.count) }
        guard ok != 0 else { throw MonitorControllerError.bridge(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
    }
    public func getMute(id: String) throws -> Bool {
        operationLock.lock(); defer { operationLock.unlock() }
        var muted: Int32 = 0; var error = [CChar](repeating: 0, count: 512)
        let ok = id.withCString { ddc_get_mute($0, &muted, &error, error.count) }
        guard ok != 0 else { throw MonitorControllerError.bridge(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        return muted != 0
    }
}
