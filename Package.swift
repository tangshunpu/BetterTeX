// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BetterTeX",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BetterTeX", targets: ["BetterTeX"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "BetterTeXCore", resources: [.process("Resources")]),
        .executableTarget(name: "BetterTeX", dependencies: ["BetterTeXCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "BetterTeXCoreTests", dependencies: ["BetterTeXCore"]),
        .testTarget(name: "BetterTeXAppTests", dependencies: ["BetterTeX"])
    ]
)
