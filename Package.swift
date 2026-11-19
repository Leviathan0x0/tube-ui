// swift-tools-version: 6.2

import Foundation
import PackageDescription

// Embed the privacy manifest into the bare executable. `swift run` has no
// app bundle, and macOS SIGKILLs the process the moment dictation asks for
// the microphone or speech recognition without these usage strings.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "TubeUI",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "TubeUI", targets: ["TubeUI"])
    ],
    targets: [
        .target(
            name: "TubeUIKit",
            path: "Sources/TubeUIKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TubeUI",
            dependencies: ["TubeUIKit"],
            path: "Sources/TubeUI",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", packageDir + "/Support/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "TubeUITests",
            dependencies: ["TubeUIKit"],
            path: "Tests/TubeUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
