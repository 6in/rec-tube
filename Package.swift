// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "rec-tube",
    // `.v26` は PackageDescription 6.2 以降（= swift-tools-version:6.2）でしか使えないので、
    // tools-version 6.0 のまま文字列で指定する（PLAN T1 の代替案）。
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RecCore", targets: ["RecCore"]),
        .executable(name: "rec", targets: ["rec"]),
        .executable(name: "rec-probe", targets: ["rec-probe"]),
    ],
    targets: [
        .target(
            name: "RecCore",
            path: "Sources/RecCore"
        ),
        // Info.plist は -sectcreate で __TEXT,__info_plist に埋め込む（リソースとして扱わせない）。
        // NSAudioCaptureUsageDescription がバイナリに無いと Core Audio の tap 許可が降りない。
        .executableTarget(
            name: "rec",
            dependencies: ["RecCore"],
            path: "Sources/rec",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/rec/Info.plist",
                ])
            ]
        ),
        // rec-probe も tap を作るので、同じく Info.plist を埋め込む
        // （NSAudioCaptureUsageDescription が無いと許可が降りず、プローブが「全ゼロ」を
        // 権限不足と区別できなくなる）。TCC 上で rec と混ざらないよう bundle ID は別にする。
        .executableTarget(
            name: "rec-probe",
            dependencies: ["RecCore"],
            path: "Sources/rec-probe",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/rec-probe/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "RecCoreTests",
            dependencies: ["RecCore"],
            path: "Tests/RecCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
