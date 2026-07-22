// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "EudoraMac",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "EudoraStore", targets: ["EudoraStore"]),
        .library(name: "EudoraSearch", targets: ["EudoraSearch"]),
        .library(name: "EudoraNet", targets: ["EudoraNet"]),
        .executable(name: "eudora-spike", targets: ["eudora-spike"]),
    ],
    targets: [
        // The reusable interop layer — the real Phase 1 seed.
        .target(name: "EudoraStore"),

        // Phase 2: full-text search index (SQLite FTS5). Uses the system
        // sqlite3, which ships with FTS5 enabled on macOS — no dependencies.
        .target(
            name: "EudoraSearch",
            dependencies: ["EudoraStore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Compose/send: RFC-822 assembly lives in EudoraStore; this target adds
        // the SMTP client + account/Keychain. Uses system Network + Security.
        .target(name: "EudoraNet", dependencies: ["EudoraStore"]),

        // Phase 0 spike, in the target language: tree / list / dump / search.
        .executableTarget(name: "eudora-spike", dependencies: ["EudoraStore", "EudoraSearch"]),

        // Tests (each builds its own temp fixture).
        .testTarget(name: "EudoraStoreTests", dependencies: ["EudoraStore"]),
        .testTarget(name: "EudoraSearchTests", dependencies: ["EudoraStore", "EudoraSearch"]),
        .testTarget(name: "EudoraNetTests", dependencies: ["EudoraNet"]),
    ]
)
