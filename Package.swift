// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacFresh",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacFresh",
            path: "Sources/MacFresh",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
