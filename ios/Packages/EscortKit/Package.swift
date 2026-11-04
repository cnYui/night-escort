// swift-tools-version: 5.9
// 手机和手表共用的逻辑：数据模型、接口客户端、到家判断、采集频率、离线上报队列。
// 不依赖 UIKit / SwiftUI，可以用 `swift test` 在 macOS（以及 Linux）上跑单元测试。
import PackageDescription

let package = Package(
    name: "EscortKit",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "EscortKit", targets: ["EscortKit"]),
    ],
    targets: [
        .target(name: "EscortKit"),
        .testTarget(name: "EscortKitTests", dependencies: ["EscortKit"]),
    ]
)
