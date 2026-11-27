// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodonProteinFactory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodonProteinFactory", targets: ["CodonProteinFactory"]),
        .library(name: "SequenceIO", targets: ["SequenceIO"]),
        .library(name: "ProteinDomain", targets: ["ProteinDomain"]),
        .library(name: "ProteinService", targets: ["ProteinService"]),
        .library(name: "ProteinApplication", targets: ["ProteinApplication"]),
        .library(name: "ProteinPersistence", targets: ["ProteinPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", exact: "0.14.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.21"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"), // MIT
    ],
    targets: [
        .executableTarget(
            name: "CodonProteinFactory",
            dependencies: ["ProteinApplication", "ProteinDomain", "ProteinPersistence", "SequenceIO"],
            path: "App",
            exclude: ["Info.plist", "Release.entitlements", "Resources"]
        ),
        .target(name: "ProteinDomain"),
        .target(
            name: "ProteinPersistence",
            dependencies: ["ProteinDomain", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "ProteinPersistenceTests",
            dependencies: ["ProteinPersistence", "ProteinDomain", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "ProteinDomainTests", dependencies: ["ProteinDomain"]),
        .target(name: "ProteinService", dependencies: ["ProteinDomain"]),
        .testTarget(name: "ProteinServiceTests", dependencies: ["ProteinService", "ProteinDomain"]),
        .target(name: "SequenceIO", dependencies: ["ZIPFoundation"]),
        .target(name: "ProteinApplication", dependencies: ["ProteinDomain", "ProteinPersistence", "ProteinService", "SequenceIO", "ZIPFoundation"]),
        .testTarget(
            name: "ProteinApplicationTests",
            dependencies: ["ProteinApplication", "ProteinDomain", "ProteinPersistence", "ProteinService", "SequenceIO", "ZIPFoundation",
                           .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SequenceIOTests",
            dependencies: ["SequenceIO", "CoreXLSX", "ZIPFoundation"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
