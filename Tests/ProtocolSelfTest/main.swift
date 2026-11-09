import Foundation
import MonitorCore

let reply: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x64, 0xd6]
precondition(RecordedFrame.ddcChecksumIsValid(reply), "recorded DDC checksum rejected")
let values = RecordedFrame.vcpValues(reply, feature: 0x62)
precondition(values?.maximum == 100 && values?.current == 100, "recorded volume values rejected")
var corrupt = reply
corrupt[9] ^= 1
precondition(RecordedFrame.vcpValues(corrupt, feature: 0x62) == nil, "corrupt reply accepted")
precondition(RecordedFrame.vcpValues(reply, feature: 0x10) == nil, "wrong feature accepted")
print("protocol self-checks passed")
