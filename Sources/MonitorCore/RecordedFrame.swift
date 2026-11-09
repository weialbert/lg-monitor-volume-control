import Foundation

/// Validation helpers shared by captured-frame diagnostics and unit tests.
public enum RecordedFrame {
    public static func ddcChecksumIsValid(_ payload: [UInt8], seed: UInt8 = 0x50) -> Bool {
        payload.reduce(seed, ^) == 0
    }
    public static func vcpValues(_ payload: [UInt8], feature: UInt8) -> (maximum: UInt16, current: UInt16)? {
        guard payload.count == 11, payload[0] == 0x6e, payload[1] == 0x88,
              payload[2] == 2, payload[3] == 0, payload[4] == feature,
              ddcChecksumIsValid(payload) else { return nil }
        let maximum = UInt16(payload[6]) << 8 | UInt16(payload[7])
        let current = UInt16(payload[8]) << 8 | UInt16(payload[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (maximum, current)
    }
}
