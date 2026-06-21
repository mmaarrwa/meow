// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "meow",
    platforms: [.iOS("16.0")],
    products: [
        .executable(
            name: "meow",
            targets: ["AppModule"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources",
            resources: [
                .process("../Info.plist"),
                // The YOLOv8n CoreML model package
                // Download from: https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.mlpackage.zip
                // Place it at: Sources/AppModule/yolov8n.mlpackage
                .process("AppModule/SurveyingModel_v1.mlpackage"),
                .process("AppModule/DepthAnythingV2SmallF16.mlpackage"),
                .process("AppModule/origin_marker.png") // See setup instructions in OriginManager.swift
            ]
        )
    ]
)