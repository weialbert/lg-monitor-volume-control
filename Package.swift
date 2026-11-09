// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LGMonitorVolumeControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MonitorCore", targets: ["MonitorCore"]),
        .executable(name: "lg-monitor-cli", targets: ["lg-monitor-cli"]),
        .executable(name: "MonitorVolumeApp", targets: ["MonitorVolumeApp"]),
        .executable(name: "protocol-self-test", targets: ["ProtocolSelfTest"]),
    ],
    targets: [
        .target(name: "DDCBridge", path: "Sources/DDCBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedFramework("CoreAudio")]),
        .target(name: "MonitorCore", dependencies: ["DDCBridge"]),
        .executableTarget(name: "lg-monitor-cli", dependencies: ["MonitorCore"]),
        .executableTarget(name: "MonitorVolumeApp", dependencies: ["MonitorCore"], path: "Sources/MonitorVolumeApp", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio"), .linkedFramework("ServiceManagement"), .linkedFramework("Carbon")]),
        .executableTarget(name: "ProtocolSelfTest", dependencies: ["MonitorCore"], path: "Tests/ProtocolSelfTest"),
    ]
)
