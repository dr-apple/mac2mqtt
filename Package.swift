// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mac2MQTTDaemon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "mac2mqttd",
            targets: ["Mac2MQTTDaemon"]
        ),
        .executable(
            name: "mac2mqtt-ui",
            targets: ["Mac2MQTTControl"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/emqx/CocoaMQTT.git", from: "2.1.8"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .executableTarget(
            name: "Mac2MQTTDaemon",
            dependencies: [
                "CocoaMQTT",
                "Yams"
            ]
        ),
        .executableTarget(
            name: "Mac2MQTTControl",
            dependencies: [
                "Yams"
            ]
        )
    ]
)
