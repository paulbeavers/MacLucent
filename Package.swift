// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacLucent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mac-lucent", targets: ["MacLucent"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MacLucent",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/MacLucent"
        )
    ]
)
