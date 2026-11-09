import Foundation
import MonitorCore

struct Output: Codable { let ok: Bool; let monitors: [Monitor]?; let monitor: Monitor?; let id: String?; let name: String?; let audioUID: String?; let volume: UInt16?; let maxVolume: UInt16?; let error: String? }
func emit<T: Encodable>(_ value: T, status: Int32 = 0) -> Never {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
    exit(status)
}
let args = Array(CommandLine.arguments.dropFirst())
let controller = MonitorController()
do {
    guard let command = args.first else { throw NSError(domain: "cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: lg-monitor-cli list|doctor|get-volume|get-mute|set-volume|mute"]) }
    switch command {
    case "list": emit(Output(ok: true, monitors: try controller.discover(), monitor: nil, id: nil, name: nil, audioUID: nil, volume: nil, maxVolume: nil, error: nil))
    case "doctor":
        let monitors = try controller.discover()
        emit(Output(ok: true, monitors: monitors, monitor: nil, id: nil, name: nil, audioUID: nil, volume: nil, maxVolume: nil, error: nil))
    case "get-volume":
        guard args.count >= 2 else { throw NSError(domain: "cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: get-volume <monitor-id>"]) }
        let v = try controller.getVolume(id: args[1]); emit(Output(ok: true, monitors: nil, monitor: nil, id: args[1], name: nil, audioUID: nil, volume: v.volume, maxVolume: v.maxVolume, error: nil))
    case "get-mute":
        guard args.count >= 2 else { throw NSError(domain: "cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: get-mute <monitor-id>"]) }
        let muted = try controller.getMute(id: args[1])
        emit(MuteOutput(ok: true, id: args[1], muted: muted, error: nil))
    case "set-volume":
        guard args.count >= 3, let value = UInt16(args[2]) else { throw NSError(domain: "cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: set-volume <monitor-id> <value>"]) }
        try controller.setVolume(id: args[1], value: value); let v = try controller.getVolume(id: args[1]); emit(Output(ok: true, monitors: nil, monitor: nil, id: args[1], name: nil, audioUID: nil, volume: v.volume, maxVolume: v.maxVolume, error: nil))
    case "mute":
        guard args.count >= 3, ["true", "false", "on", "off"].contains(args[2]) else { throw NSError(domain: "cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: mute <monitor-id> true|false"]) }
        try controller.mute(id: args[1], args[2] == "true" || args[2] == "on"); emit(Output(ok: true, monitors: nil, monitor: nil, id: args[1], name: nil, audioUID: nil, volume: nil, maxVolume: nil, error: nil))
    default: throw NSError(domain: "cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown command: \(command)"])
    }

struct MuteOutput: Codable { let ok: Bool; let id: String; let muted: Bool; let error: String? }
} catch { emit(Output(ok: false, monitors: nil, monitor: nil, id: nil, name: nil, audioUID: nil, volume: nil, maxVolume: nil, error: error.localizedDescription), status: 1) }
