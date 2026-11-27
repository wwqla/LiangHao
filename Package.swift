// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiangHao",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LiangHao",
            path: "Sources/LiangHao"
        )
    ]
)
