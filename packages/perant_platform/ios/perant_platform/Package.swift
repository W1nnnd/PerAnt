// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "perant_platform",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "perant-platform", targets: ["perant_platform"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "perant_platform",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
