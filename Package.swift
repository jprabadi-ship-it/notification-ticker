// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotificationTicker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotificationTicker", targets: ["NotificationTicker"])
    ],
    targets: [
        .executableTarget(
            name: "NotificationTicker",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .testTarget(
            name: "NotificationTickerTests",
            dependencies: ["NotificationTicker"]
        )
    ],
    swiftLanguageModes: [.v5]
)
