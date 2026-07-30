// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-ip-registry",
    platforms: [.macOS(.v13)],
    targets: [
        // Wire format, minimal HTTP, and the BSD/IOKit lookups both binaries need.
        .target(
            name: "IPReportCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Everything the collector does that isn't a socket: storage, routing, rendering.
        // Split out so the full HTTP surface is testable without binding a port.
        .target(name: "CollectorKit", dependencies: ["IPReportCore"]),
        .executableTarget(name: "ipcollector", dependencies: ["CollectorKit"]),
        .executableTarget(name: "ipreporter", dependencies: ["IPReportCore"]),
        .testTarget(name: "CollectorKitTests", dependencies: ["CollectorKit"]),
    ]
)
