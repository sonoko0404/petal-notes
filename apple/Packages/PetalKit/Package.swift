// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PetalKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PetalCore", targets: ["PetalCore"]),
        .library(name: "PetalPersistence", targets: ["PetalPersistence"]),
        .library(name: "PetalSync", targets: ["PetalSync"]),
        .library(name: "PetalNotifications", targets: ["PetalNotifications"]),
        .library(name: "PetalImportExport", targets: ["PetalImportExport"]),
        .library(name: "PetalDesignSystem", targets: ["PetalDesignSystem"]),
        .library(name: "PetalActions", targets: ["PetalActions"]),
        .library(name: "PetalTestSupport", targets: ["PetalTestSupport"]),
    ],
    targets: [
        .target(name: "PetalCore"),
        .target(name: "PetalPersistence", dependencies: ["PetalCore"]),
        .target(name: "PetalSync", dependencies: ["PetalCore", "PetalPersistence"]),
        .target(name: "PetalNotifications", dependencies: ["PetalCore"]),
        .target(name: "PetalImportExport", dependencies: ["PetalCore", "PetalPersistence"]),
        .target(name: "PetalDesignSystem", dependencies: ["PetalCore"]),
        .target(name: "PetalActions", dependencies: ["PetalPersistence", "PetalSync", "PetalNotifications"]),
        .target(name: "PetalTestSupport", dependencies: ["PetalCore", "PetalPersistence"]),
        .testTarget(name: "PetalCoreTests", dependencies: ["PetalCore"]),
        .testTarget(name: "PetalPersistenceTests", dependencies: ["PetalPersistence", "PetalTestSupport"]),
        .testTarget(name: "PetalSyncTests", dependencies: ["PetalSync", "PetalTestSupport"]),
        .testTarget(name: "PetalNotificationsTests", dependencies: ["PetalNotifications"]),
        .testTarget(name: "PetalImportExportTests", dependencies: ["PetalImportExport", "PetalTestSupport"]),
        .testTarget(name: "PetalDesignSystemTests", dependencies: ["PetalDesignSystem"]),
    ]
)
