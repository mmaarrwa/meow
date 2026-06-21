import Foundation
import Combine
import UIKit

// MARK: - SettingsManager
// Single source of truth for all user-configurable parameters.
// All values persist across sessions via UserDefaults.

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    // MARK: - Camera Height
    @Published var cameraHeight: Float {
        didSet { UserDefaults.standard.set(cameraHeight, forKey: "cameraHeight") }
    }

    // MARK: - Laser Scan (System B)
    @Published var numScanColumns: Int {
        didSet { UserDefaults.standard.set(numScanColumns, forKey: "numScanColumns") }
    }
    @Published var numScanRows: Int {
        didSet { UserDefaults.standard.set(numScanRows, forKey: "numScanRows") }
    }
    @Published var smoothingAlpha: Float {
        didSet { UserDefaults.standard.set(smoothingAlpha, forKey: "smoothingAlpha") }
    }
    @Published var maxMissTolerance: Int {
        didSet { UserDefaults.standard.set(maxMissTolerance, forKey: "maxMissTolerance") }
    }
    @Published var verticalCenterOffset: Double {
        didSet { UserDefaults.standard.set(verticalCenterOffset, forKey: "verticalCenterOffset") }
    }
    @Published var verticalSpread: Double {
        didSet { UserDefaults.standard.set(verticalSpread, forKey: "verticalSpread") }
    }
    @Published var horizontalSpread: Double {
        didSet { UserDefaults.standard.set(horizontalSpread, forKey: "horizontalSpread") }
    }
    @Published var maxRayDistance: Float {
        didSet { UserDefaults.standard.set(maxRayDistance, forKey: "maxRayDistance") }
    }
    @Published var minRayDistance: Float {
        didSet { UserDefaults.standard.set(minRayDistance, forKey: "minRayDistance") }
    }

    //debugging features
    @Published var showDebugPlanes: Bool {
        didSet { UserDefaults.standard.set(showDebugPlanes, forKey: "showDebugPlanes") }
    }
    @Published var showDebugMesh: Bool {
        didSet { UserDefaults.standard.set(showDebugMesh, forKey: "showDebugMesh") }
    }

    // MARK: - Detection (System A)
    @Published var confidenceThreshold: Float {
        didSet { UserDefaults.standard.set(confidenceThreshold, forKey: "confidenceThreshold") }
    }

    // MARK: - Network
    @Published var serverIP: String {
        didSet { UserDefaults.standard.set(serverIP, forKey: "serverIP") }
    }

    private init() {
        // Load from UserDefaults with sensible defaults
        cameraHeight         = UserDefaults.standard.float(forKey: "cameraHeight")
                                .nonZero ?? 1.2
        numScanColumns       = UserDefaults.standard.integer(forKey: "numScanColumns")
                                .nonZero ?? 30
        numScanRows          = UserDefaults.standard.integer(forKey: "numScanRows")
                                .nonZero ?? 5
        smoothingAlpha       = UserDefaults.standard.float(forKey: "smoothingAlpha")
                                .nonZero ?? 0.2
        maxMissTolerance     = UserDefaults.standard.integer(forKey: "maxMissTolerance")
                                .nonZero ?? 3
        verticalCenterOffset = UserDefaults.standard.double(forKey: "verticalCenterOffset")
                                .nonZero ?? 0.65
        horizontalSpread     = UserDefaults.standard.double(forKey: "horizontalSpread")
                                .nonZero ?? 0.80
        verticalSpread       = UserDefaults.standard.double(forKey: "verticalSpread")
                                .nonZero ?? 0.20
        maxRayDistance       = UserDefaults.standard.float(forKey: "maxRayDistance")
                                .nonZero ?? 3.0
        minRayDistance       = UserDefaults.standard.float(forKey: "minRayDistance")
                                .nonZero ?? 0.15
        confidenceThreshold  = UserDefaults.standard.float(forKey: "confidenceThreshold")
                                .nonZero ?? 0.40
        showDebugPlanes = UserDefaults.standard.bool(forKey: "showDebugPlanes")
        showDebugMesh   = UserDefaults.standard.bool(forKey: "showDebugMesh")
        serverIP             = UserDefaults.standard.string(forKey: "serverIP") ?? "192.168.1.10"
    }
    // MARK: - Dynamic Orientation Helper
    // Shared across the app for SurveyingModel_v1 and Depth models
    func currentCameraOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
            case .landscapeLeft:  return .up    // FLIPPED to fix the 180-degree bug
            case .landscapeRight: return .down  // FLIPPED to fix the 180-degree bug
            case .portraitUpsideDown: return .left
            default: return .right // Portrait
        }
    }
}

// MARK: - Helpers
private extension Float {
    var nonZero: Float? { self == 0 ? nil : self }
}
private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

