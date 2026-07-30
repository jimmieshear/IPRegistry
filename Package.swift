// swift-tools-version:6.0
import PackageDescription

// The collector runs on macOS and Linux; the reporter is macOS-only, since it reads the
// IORegistry and watches NWPathMonitor. IOKit is therefore linked only into ipreporter,
// keeping IPReportCore and CollectorKit portable enough to cross-compile for the VPS.
let package = Package(
    name: "mac-ip-registry",
    platforms: [.macOS(.v13)],
    targets: [
        // Models, wire format, minimal HTTP, portable libc helpers. No platform frameworks.
        .target(name: "IPReportCore"),

        // Storage, routing, dashboard, and a POSIX socket server. Portable.
        .target(name: "CollectorKit", dependencies: ["IPReportCore"]),

        .executableTarget(name: "ipcollector", dependencies: ["CollectorKit"]),

        .executableTarget(
            name: "ipreporter",
            dependencies: ["IPReportCore"],
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]
        ),

        .testTarget(name: "CollectorKitTests", dependencies: ["CollectorKit"]),
    ]
)
