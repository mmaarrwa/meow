import Foundation
import Combine

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
    @Published var verticalCenterOffset: Double {
        didSet { UserDefaults.standard.set(verticalCenterOffset, forKey: "verticalCenterOffset") }
    }
    @Published var verticalSpread: Double {
        didSet { UserDefaults.standard.set(verticalSpread, forKey: "verticalSpread") }
    }
    @Published var maxRayDistance: Float {
        didSet { UserDefaults.standard.set(maxRayDistance, forKey: "maxRayDistance") }
    }
    @Published var minRayDistance: Float {
        didSet { UserDefaults.standard.set(minRayDistance, forKey: "minRayDistance") }
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
        verticalCenterOffset = UserDefaults.standard.double(forKey: "verticalCenterOffset")
                                .nonZero ?? 0.65
        verticalSpread       = UserDefaults.standard.double(forKey: "verticalSpread")
                                .nonZero ?? 0.20
        maxRayDistance       = UserDefaults.standard.float(forKey: "maxRayDistance")
                                .nonZero ?? 3.0
        minRayDistance       = UserDefaults.standard.float(forKey: "minRayDistance")
                                .nonZero ?? 0.15
        confidenceThreshold  = UserDefaults.standard.float(forKey: "confidenceThreshold")
                                .nonZero ?? 0.40
        serverIP             = UserDefaults.standard.string(forKey: "serverIP") ?? "192.168.1.10"
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