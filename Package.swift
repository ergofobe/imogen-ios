// swift-tools-version: 5.9
import PackageDescription

/**
 The parts of the application that are not a view.

 Accounts, sessions, pairing, the timeline arithmetic and the upload ledger live here
 rather than in the app target, and the package does not import UIKit — which means
 `swift test` runs the whole of it on any machine with a toolchain, without Xcode, without
 a simulator, and in under a second.

 The app target is the SwiftUI layer and the frameworks that only exist on a phone:
 PhotoKit, AVFoundation's capture stack, background tasks.
 */
let package = Package(
    name: "ImogenKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ImogenKit", targets: ["ImogenKit"]),
    ],
    dependencies: [
        .package(path: "imogen-sdk/swift"),
    ],
    targets: [
        .target(
            name: "ImogenKit",
            dependencies: [.product(name: "ImogenSDK", package: "swift")]
        ),
        .testTarget(name: "ImogenKitTests", dependencies: ["ImogenKit"]),
    ]
)
