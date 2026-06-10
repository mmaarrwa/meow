import Foundation
import ARKit
import simd
import UIKit // <-- 1. ADDED THIS to safely load images

// MARK: - Origin Marker Detection Data
// Produced every frame the marker is visible.
struct OriginMarkerData {
    /// Full 4×4 transform of the marker in ARKit world frame
    let worldTransform: simd_float4x4
    /// World-space position of the marker centre
    let worldPosition: SIMD3<Float>
    /// Euclidean distance from camera to marker centre (metres)
    let distanceMeters: Float
    /// Bearing angle (radians) from robot forward axis to marker
    /// Positive = marker is to the right
    let bearingRadians: Float
    /// ARFrame timestamp
    let timestamp: TimeInterval
}

// MARK: - OriginMarkerManager
// Detects a single high-entropy printed image (the "origin marker") using
// ARKit's native image tracking.  Produces distance + bearing + pose data
// for loop closure — the actual drift correction is handled in ROS.
//
// The marker image must be a high-detail photograph or complex graphic
// (NOT an ArUco marker — ARKit struggles with low-entropy images).
// Print it at exactly the size set in markerPhysicalWidth below.

final class OriginMarkerManager {
    static let shared = OriginMarkerManager()

    // MARK: - Configuration

    /// Physical width of the printed marker in metres.
    /// Measure with a ruler after printing — this is critical for accurate depth.
    static let markerPhysicalWidth: Float  = 0.116
    static let markerPhysicalHeight: Float = 0.275

    /// The image name as it appears in the asset catalogue AR group
    /// or as a plain PNG in the bundle.
    static let markerImageName = "origin_marker"

    // MARK: - State

    /// Most recent marker data — nil until START pressed and marker first seen
    private(set) var currentData: OriginMarkerData?

    /// True while marker is actively tracked in current frame
    private(set) var isVisible: Bool = false

    /// How many times marker has been detected since last START
    private(set) var detectionCount: Int = 0

    /// Set to true by ARManager when START is pressed.
    /// Resets all state so detections before START are ignored.
    var isActive: Bool = false {
        didSet {
            if isActive {
                // Clear any data from before START was pressed
                currentData    = nil
                isVisible      = false
                detectionCount = 0
                log("🔄 Origin marker manager reset — ready for new session")
            }
        }
    }

    /// Fired on main thread whenever new marker data is available
    var onMarkerUpdated: ((OriginMarkerData) -> Void)?

    /// Debug log sink → forwarded to UDP by ARManager
    var onDebugLog: ((String) -> Void)?

    private init() {}

    // MARK: - Reference Image Setup
    // Call this when building the ARWorldTrackingConfiguration.

    // MARK: - Invincible Image Loader
    func referenceImages() -> Set<ARReferenceImage> {
        // 1. Check inside Apple's hidden compiled databases (Assets.car)
        for bundle in Bundle.allBundles {
            if let image = UIImage(named: Self.markerImageName, in: bundle, compatibleWith: nil),
               let cgImage = image.cgImage {
                log("✅ Found origin_marker inside compiled assets of bundle: \(bundle.bundleURL.lastPathComponent)")
                let ref = ARReferenceImage(cgImage: cgImage, orientation: .up, physicalWidth: CGFloat(Self.markerPhysicalWidth))
                ref.name = Self.markerImageName
                return [ref]
            }
        }

        // 2. Fallback: Brute-Force Folder Search (If it is sitting loose in a folder)
        if let resourceURL = Bundle.main.resourceURL {
            let fm = FileManager.default
            if let enumerator = fm.enumerator(at: resourceURL, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent == "\(Self.markerImageName).png" {
                        log("✅ Found loose origin_marker.png at: \(fileURL.path)")
                        if let img = UIImage(contentsOfFile: fileURL.path),
                           let cg = img.cgImage {
                            let ref = ARReferenceImage(cgImage: cg, orientation: .up, physicalWidth: CGFloat(Self.markerPhysicalWidth))
                            ref.name = Self.markerImageName
                            return [ref]
                        }
                    }
                }
            }
        }
        
        log("❌ origin_marker not found in Assets OR loose folders.")
        return []
    }

    // MARK: - Anchor Callbacks
    // Call both from ARSessionDelegate in ARManager.

    func handleAnchorAdded(_ anchor: ARAnchor, frame: ARFrame) {
        // 3. THE FIX: Commented this out so it tracks before you press START
        // guard isActive else { return } 
        
        guard let imageAnchor = anchor as? ARImageAnchor,
              imageAnchor.referenceImage.name == Self.markerImageName else { return }
        detectionCount += 1
        log("🎯 Origin marker DETECTED (session count: \(detectionCount))")
        process(imageAnchor, frame: frame)
    }

    func handleAnchorUpdated(_ anchor: ARAnchor, frame: ARFrame) {
        // 3. THE FIX: Commented this out so it tracks before you press START
        // guard isActive else { return }
        
        guard let imageAnchor = anchor as? ARImageAnchor,
              imageAnchor.referenceImage.name == Self.markerImageName else { return }
        isVisible = imageAnchor.isTracked
        if imageAnchor.isTracked {
            process(imageAnchor, frame: frame)
        } else {
            log("👁 Origin marker left view")
        }
    }

    // MARK: - Pose Computation

    private func process(_ anchor: ARImageAnchor, frame: ARFrame) {
        isVisible = true

        let markerTransform = anchor.transform
        let markerPos = SIMD3<Float>(
            markerTransform.columns.3.x,
            markerTransform.columns.3.y,
            markerTransform.columns.3.z
        )

        let camTransform = frame.camera.transform
        let camPos = SIMD3<Float>(
            camTransform.columns.3.x,
            camTransform.columns.3.y,
            camTransform.columns.3.z
        )

        let diff     = markerPos - camPos
        let distance = simd_length(diff)
        // Bearing in the horizontal XZ plane
        // atan2(X, Z) gives angle from forward (Z) axis
        let bearing  = atan2(diff.x, diff.z)

        let data = OriginMarkerData(
            worldTransform: markerTransform,
            worldPosition:  markerPos,
            distanceMeters: distance,
            bearingRadians: bearing,
            timestamp:      frame.timestamp
        )
        currentData = data

        log(String(format: "📍 Marker | dist=%.2fm | bearing=%.1f°",
                   distance, bearing * 180 / .pi))

        DispatchQueue.main.async { [weak self] in
            self?.onMarkerUpdated?(data)
        }
    }

    // MARK: - Helpers

    // You don't actually need this function anymore since we use UIImage, 
    // but I am leaving it here so your code matches your original exactly!
    private func loadCGImage(from url: URL) -> CGImage? {
        guard let data     = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(pngDataProviderSource: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private func log(_ msg: String) {
        onDebugLog?(msg)
        print("[OriginMarkerManager] \(msg)")
    }
}