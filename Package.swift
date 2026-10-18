// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShiftDrop",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ShiftDropCore", targets: ["ShiftDropCore"]), .executable(name: "ShiftDrop", targets: ["ShiftDrop"])],
    targets: [
        .target(name: "ShiftDropCore"),
        .executableTarget(name: "ShiftDrop", dependencies: ["ShiftDropCore"]),
        .testTarget(name: "ShiftDropCoreTests", dependencies: ["ShiftDropCore"]),
        .testTarget(name: "ShiftDropAppTests", dependencies: ["ShiftDrop", "ShiftDropCore"])
    ]
)
