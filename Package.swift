// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .executable(name: "CallRecorder", targets: ["CallRecorderApp"]),
        .executable(name: "CallRecorderTests", targets: ["CallRecorderTests"]),
    ],
    targets: [
        .target(
            name: "AudioCaptureBridge",
            path: "Sources/AudioCaptureBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "CallRecorderCore",
            dependencies: ["AudioCaptureBridge"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "CallRecorderApp",
            dependencies: ["CallRecorderCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "CallRecorderTests",
            dependencies: ["CallRecorderCore"],
            path: "Tests/CallRecorderCoreTests",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
