// swift-tools-version: 6.2
import Foundation
import PackageDescription

let runtime =
    ProcessInfo.processInfo.environment["GLASSDOCK_VM_RUNTIME_SOURCE"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/machines/UTM.app")
let frameworks = runtime.appendingPathComponent("Contents/Frameworks").standardizedFileURL.path
let package = Package(
    name: "GlassDockMachinesApp", platforms: [.macOS(.v15)], products: [.executable(name: "GlassDockMachinesApp", targets: ["GlassDockMachinesApp"])],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../../.build/machines/CocoaSpice"),
    ],
    targets: [
        .executableTarget(
            name: "GlassDockMachinesApp",
            dependencies: [
                .product(name: "GlassDockMachines", package: "glassdock"),
                .product(name: "CocoaSpice", package: "CocoaSpice"),
            ], path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-F", frameworks, "-Xlinker", "-rpath", "-Xlinker", frameworks]),
                .linkedFramework("spice-client-glib-2.0.8"), .linkedFramework("glib-2.0.0"), .linkedFramework("gobject-2.0.0"),
                .linkedFramework("gio-2.0.0"), .linkedFramework("gstreamer-1.0.0"), .linkedFramework("gstapp-1.0.0"), .linkedFramework("gstvideo-1.0.0"),
                .linkedFramework("usb-1.0.0"), .linkedFramework("usbredirhost.1"), .linkedFramework("usbredirparser.1"), .linkedFramework("phodav-3.0.0"),
                .linkedFramework("soup-3.0.0"),
            ])
    ])
