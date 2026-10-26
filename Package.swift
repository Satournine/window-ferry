// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowFerry",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowFerry", targets: ["WindowFerry"])],
    targets: [
        .target(name: "FerryCore"),
        .executableTarget(name: "WindowFerry", dependencies: ["FerryCore"],
                          linkerSettings: [.linkedFramework("AppKit"),
                                           .linkedFramework("ApplicationServices"),
                                           .linkedFramework("Carbon")])
    ]
)
