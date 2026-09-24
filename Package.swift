// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceMongerMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpaceMongerMac",
            path: "Sources/SpaceMongerMac",
            // AppIcon.png: the original's res/SpaceMonger.ico (32×32, 16 colors)
            // upscaled 16× nearest-neighbor so the pixel art stays crisp.
            resources: [.copy("Resources/AppIcon.png")],
            // NetFS: Connect to Server… mounts SMB/AFP/NFS/WebDAV shares.
            linkerSettings: [.linkedFramework("NetFS")]
        )
    ]
)