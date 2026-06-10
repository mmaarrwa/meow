import Foundation
import ARKit
import simd

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
    static let markerPhysicalWidth: Float  = 0.23
    static let markerPhysicalHeight: Float = 0.23

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

    func referenceImages() -> Set<ARReferenceImage> {
        // Try asset catalogue first (OPTION A)
        if let images = ARReferenceImage.referenceImages(
            inGroupNamed: "ARResources", bundle: .main), !images.isEmpty {
            log("✅ Loaded \(images.count) reference image(s) from asset catalogue")
            return images
        }

        // Fallback: plain PNG in bundle (OPTION B)
        guard let url     = Bundle.main.url(forResource: Self.markerImageName,
                                            withExtension: "png"),
              let cgImage = loadCGImage(from: url) else {
            log("❌ \(Self.markerImageName).png not found in bundle — see setup notes")
            return []
        }

        let ref      = ARReferenceImage(cgImage,
                                        orientation: .up,
                                        physicalWidth: CGFloat(Self.markerPhysicalWidth))
        ref.name     = Self.markerImageName
        log("✅ Loaded reference image from bundle PNG")
        return [ref]
    }

    // MARK: - Anchor Callbacks
    // Call both from ARSessionDelegate in ARManager.

    func handleAnchorAdded(_ anchor: ARAnchor, frame: ARFrame) {
        guard isActive else { return }
        guard let imageAnchor = anchor as? ARImageAnchor,
              imageAnchor.referenceImage.name == Self.markerImageName else { return }
        detectionCount += 1
        log("🎯 Origin marker DETECTED (session count: \(detectionCount))")
        process(imageAnchor, frame: frame)
    }

    func handleAnchorUpdated(_ anchor: ARAnchor, frame: ARFrame) {
        guard isActive else { return }
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

// MARK: - ═══════════════════════════════════════════════════════════════
// SETUP INSTRUCTIONS
// ════════════════════════════════════════════════════════════════════════
//
// STEP 1 — Choose your marker image
//   Use any high-detail photograph or complex graphic.
//   Requirements:
//     • Rich texture, lots of fine detail
//     • Asymmetric (so ARKit knows which way is up)
//     • High contrast
//     • NO ArUco / QR codes — they have too little visual complexity
//   Good choices: a detailed city photo, a dense illustrated poster,
//   a custom graphic with many geometric shapes and text.
//
// STEP 2 — Print it
//   Print at A4 size (21 × 29.7 cm).
//   Measure the actual printed width with a ruler and update
//   markerPhysicalWidth above if your printer scaled it.
//   Laminate if possible — flat surface gives better tracking.
//
// STEP 3 — Add the image to the project (pick ONE option):
//
//   OPTION A — Asset Catalogue (recommended for Xcode projects):
//     • Create an Asset Catalogue named "ARResources.xcassets"
//     • Inside it create an "AR Resource Group"
//     • Drag your image in, set Units=Meters, width=0.21, height=0.297
//     • In Package.swift resources: .process("ARResources.xcassets")
//
//   OPTION B — Plain PNG (simpler for SPM without Xcode):
//     • Name the file "origin_marker.png"
//     • Copy it into Sources/AppModule/
//     • In Package.swift resources: .process("AppModule/origin_marker.png")
//
// STEP 4 — Physical placement
//   Place the printed marker flat on the floor (or vertical on a stand)
//   at the exact point you want to be the robot's origin.
//   The marker's centre = world origin after START is pressed.
// ════════════════════════════════════════════════════════════════════════