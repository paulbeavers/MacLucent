// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacLucent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mac-lucent", targets: ["MacLucent"])
    ],
    dependencies: [
        // 1.99.x (pre-2.0) introduced an off-main render loop that stalls 150–300 ms on real typing.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.1")
    ],
    targets: [
        .executableTarget(
            name: "MacLucent",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/MacLucent"
        )
    ]
)
