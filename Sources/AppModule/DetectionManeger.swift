import Foundation
import Vision
import CoreML
import ARKit
import simd

// MARK: - Data Model
struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let normalizedRect: CGRect      // Vision normalised rect (bottom-left origin)
    let distanceMeters: Float
    let distanceMethod: String      // M1–M5
    let worldPosition: SIMD3<Float> // World-space XYZ (ARKit world frame)
}

// MARK: - DetectionManager
// Runs YOLOv8 inference and computes per-detection world position using
// a 5-stage cascade. World position is always in the ARKit world frame
// (origin = where START was pressed).

final class DetectionManager {
    static let shared = DetectionManager()

    // Set by ARManager so M2/M3 can call into ARSCNView on main thread
    weak var sceneView: ARSCNView?

    // Called on main thread with results each processed frame
    var onDetections: (([DetectedObject], CGSize) -> Void)?

    // Debug log sink → forwarded to UDP
    var onDebugLog: ((String) -> Void)?

    private var visionRequest: VNCoreMLRequest?
    private let settings = SettingsManager.shared

    // M3 hit-test grid params
    private let hitTestGridSize     = 3
    private let hitTestGridRadius:  Float = 0.03
    private let hitTestMinDist:     Float = 0.15
    private let hitTestMaxDist:     Float = 15.0

    // M4 feature point cone params
    private let fpConeHalfWidth:    Float = 0.25
    private let fpConeHalfHeight:   Float = 0.25
    private let fpNearZ:            Float = 0.20
    private let fpFarZ:             Float = 15.0
    private let fpDensityThreshold: Int   = 8

    private init() { setupModel() }

    // MARK: - Model Setup
    private func setupModel() {
        guard let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")
                          ?? Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage") else {
            log("⚠️ YOLOv8n model not found")
            return
        }
        do {
            let config  = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            let vnModel = try VNCoreMLModel(for: mlModel)
            visionRequest = VNCoreMLRequest(model: vnModel) { [weak self] _, error in
                if let error = error { self?.log("Vision error: \(error)") }
            }
            visionRequest?.imageCropAndScaleOption = .scaleFill
            log("✅ YOLOv8n loaded")
        } catch {
            log("❌ Failed to load model: \(error)")
        }
    }

    // MARK: - Process Frame
    func processFrame(_ frame: ARFrame) {
        guard let request = visionRequest else { return }

        let pixelBuffer  = frame.capturedImage
        let imageSize    = CGSize(width:  CVPixelBufferGetWidth(pixelBuffer),
                                  height: CVPixelBufferGetHeight(pixelBuffer))
        let intrinsics   = frame.camera.intrinsics
        let camTransform = frame.camera.transform

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,
                                            options: [:])
        do    { try handler.perform([request]) }
        catch { log("Vision perform error: \(error)"); return }

        guard let results = request.results as? [VNRecognizedObjectObservation] else { return }

        var detections: [DetectedObject] = []

        for obs in results {
            guard let top = obs.labels.first,
                  top.confidence >= settings.confidenceThreshold else { continue }

            let bbox = obs.boundingBox

            let (dist, method, worldPos) = computeDistance(
                boundingBox:     bbox,
                frame:           frame,
                imageSize:       imageSize,
                intrinsics:      intrinsics,
                cameraTransform: camTransform
            )

            log("[\(method)] \(top.identifier) → \(String(format: "%.2f", dist))m")

            detections.append(DetectedObject(
                label:          top.identifier,
                confidence:     top.confidence,
                normalizedRect: bbox,
                distanceMeters: dist,
                distanceMethod: method,
                worldPosition:  worldPos
            ))
        }

        DispatchQueue.main.async { [weak self] in
            self?.onDetections?(detections, imageSize)
        }
    }

    // MARK: - 5-Stage Distance + World Position Cascade

    private func computeDistance(
        boundingBox     bbox:            CGRect,
        frame:                           ARFrame,
        imageSize:                       CGSize,
        intrinsics:                      simd_float3x3,
        cameraTransform:                 simd_float4x4
    ) -> (Float, String, SIMD3<Float>) {

        // Bbox centre in ARKit normalised space (top-left origin, Y flipped)
        let normX = Float(bbox.midX)
        let normY = Float(1.0 - (bbox.minY + bbox.height / 2.0))

        let camPos = SIMD3<Float>(cameraTransform.columns.3.x,
                                   cameraTransform.columns.3.y,
                                   cameraTransform.columns.3.z)

        // ── M1: LiDAR ───────────────────────────────────────────────
        if let (d, wp) = m1_lidar(frame: frame, normX: normX, normY: normY,
                                   camPos: camPos, camTransform: cameraTransform,
                                   intrinsics: intrinsics) {
            return (clamp(d), "M1", wp)
        }

        // ── M2: ARKit raycast ────────────────────────────────────────
        if let (d, wp) = m2_raycast(frame: frame, normX: normX, normY: normY,
                                     camPos: camPos) {
            return (clamp(d), "M2", wp)
        }

        // ── M3: Legacy hitTest ───────────────────────────────────────
        if let (d, wp) = m3_hitTest(normX: normX, normY: normY, camPos: camPos,
                                     cameraTransform: cameraTransform) {
            return (clamp(d), "M3", wp)
        }

        // ── M4: Feature point density ────────────────────────────────
        if let (d, wp) = m4_featurePoints(frame: frame, bbox: bbox,
                                           camPos: camPos,
                                           cameraTransform: cameraTransform) {
            return (clamp(d), "M4", wp)
        }

        // ── M5: Geometric ray–ground intersection ────────────────────
        let (d, wp) = m5_geometric(bbox: bbox, imageSize: imageSize,
                                    intrinsics: intrinsics,
                                    cameraTransform: cameraTransform)
        return (clamp(d), "M5", wp)
    }

    // MARK: - M1: LiDAR
    private func m1_lidar(frame: ARFrame,
                           normX: Float, normY: Float,
                           camPos: SIMD3<Float>,
                           camTransform: simd_float4x4,
                           intrinsics: simd_float3x3) -> (Float, SIMD3<Float>)? {

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w  = CVPixelBufferGetWidth(depthMap)
        let h  = CVPixelBufferGetHeight(depthMap)
        let px = max(0, min(Int(normX * Float(w)), w - 1))
        let py = max(0, min(Int(normY * Float(h)), h - 1))

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depth = base.assumingMemoryBound(to: Float32.self)[py * w + px]
        guard depth > 0.01 else { return nil }

        // Back-project depth to world position
        let fx = intrinsics.columns.0.x; let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x; let cy = intrinsics.columns.2.y
        let imageRes = frame.camera.imageResolution
        let ub = normX * Float(imageRes.width)
        let vb = normY * Float(imageRes.height)
        let Xc = ((ub - cx) / fx) * depth
        let Yc = ((vb - cy) / fy) * depth
        let Zc = -depth
        let localPt = simd_float4(Xc, Yc, Zc, 1)
        let worldPt = camTransform * localPt
        let wp = SIMD3<Float>(worldPt.x, worldPt.y, worldPt.z)
        return (simd_length(wp - camPos), wp)
    }

    // MARK: - M2: ARKit raycast
    private func m2_raycast(frame: ARFrame,
                             normX: Float, normY: Float,
                             camPos: SIMD3<Float>) -> (Float, SIMD3<Float>)? {
        guard let sv = sceneView else { return nil }
        var result: (Float, SIMD3<Float>)? = nil
        let sem = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            defer { sem.signal() }
            let bounds = sv.bounds
            let pt = CGPoint(x: CGFloat(normX) * bounds.width,
                             y: CGFloat(normY) * bounds.height)

            for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
                guard let query = sv.raycastQuery(from: pt, allowing: target,
                                                  alignment: .any) else { continue }
                if let hit = sv.session.raycast(query).first {
                    let wp = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                          hit.worldTransform.columns.3.y,
                                          hit.worldTransform.columns.3.z)
                    let d = simd_length(wp - camPos)
                    if d > self.hitTestMinDist { result = (d, wp); return }
                }
            }
        }
        sem.wait()
        return result
    }

    // MARK: - M3: Legacy hitTest
    private func m3_hitTest(normX: Float, normY: Float,
                             camPos: SIMD3<Float>,
                             cameraTransform: simd_float4x4) -> (Float, SIMD3<Float>)? {
        guard let sv = sceneView else { return nil }
        var result: (Float, SIMD3<Float>)? = nil
        let sem = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            defer { sem.signal() }
            let bounds = sv.bounds
            let cx = CGFloat(normX) * bounds.width
            let cy = CGFloat(normY) * bounds.height
            let radius = CGFloat(self.hitTestGridRadius) * min(bounds.width, bounds.height)

            var best: Float = .greatestFiniteMagnitude
            var bestPos: SIMD3<Float>? = nil
            let half = (self.hitTestGridSize - 1) / 2

            for i in 0..<self.hitTestGridSize {
                for j in 0..<self.hitTestGridSize {
                    let ox = CGFloat(i - half) / CGFloat(max(1, half))
                    let oy = CGFloat(j - half) / CGFloat(max(1, half))
                    let pt = CGPoint(x: cx + ox * radius, y: cy + oy * radius)

                    if let hit = sv.hitTest(pt, types: [.featurePoint,
                                                         .existingPlaneUsingExtent,
                                                         .estimatedHorizontalPlane]).first {
                        let wp = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                              hit.worldTransform.columns.3.y,
                                              hit.worldTransform.columns.3.z)
                        let d = simd_length(wp - camPos)
                        if d >= self.hitTestMinDist && d <= self.hitTestMaxDist && d < best {
                            best = d; bestPos = wp
                        }
                    }
                }
            }
            if let wp = bestPos { result = (best, wp) }
        }
        sem.wait()
        return result
    }

    // MARK: - M4: Feature point density
    private func m4_featurePoints(frame: ARFrame,
                                   bbox: CGRect,
                                   camPos: SIMD3<Float>,
                                   cameraTransform: simd_float4x4) -> (Float, SIMD3<Float>)? {
        guard let rawPoints = frame.rawFeaturePoints?.points,
              !rawPoints.isEmpty else { return nil }

        let worldToCam = cameraTransform.inverse
        let coneW = max(fpConeHalfWidth,  Float(bbox.width)  * 0.5)
        let coneH = max(fpConeHalfHeight, Float(bbox.height) * 0.5)

        var count    = 0
        var nearestZ = Float.greatestFiniteMagnitude
        var nearestWorldPos: SIMD3<Float>? = nil

        for p in rawPoints {
            let local = simd_mul(worldToCam, simd_float4(p.x, p.y, p.z, 1))
            let absZ  = -local.z
            guard absZ > fpNearZ && absZ < fpFarZ else { continue }
            guard abs(local.x / absZ) <= coneW,
                  abs(local.y / absZ) <= coneH else { continue }
            count += 1
            if absZ < nearestZ {
                nearestZ = absZ
                nearestWorldPos = SIMD3<Float>(p.x, p.y, p.z)
            }
        }

        guard count >= fpDensityThreshold,
              let wp = nearestWorldPos else { return nil }
        return (nearestZ, wp)
    }

    // MARK: - M5: Geometric ray–ground intersection
    private func m5_geometric(bbox: CGRect,
                               imageSize: CGSize,
                               intrinsics: simd_float3x3,
                               cameraTransform: simd_float4x4) -> (Float, SIMD3<Float>) {

        let fx = intrinsics.columns.0.x; let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x; let cy = intrinsics.columns.2.y

        let ubNorm = Float(bbox.midX)
        let vbNorm = Float(1.0 - bbox.minY)
        let ub = ubNorm * Float(imageSize.width)
        let vb = vbNorm * Float(imageSize.height)

        let xn = (ub - cx) / fx
        let yn = (vb - cy) / fy

        let rayCamera = simd_float3(xn, yn, -1.0)
        let R = simd_float3x3(
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        let rayWorld = simd_normalize(R * rayCamera)

        let camPos  = SIMD3<Float>(cameraTransform.columns.3.x,
                                    cameraTransform.columns.3.y,
                                    cameraTransform.columns.3.z)
        let groundY = camPos.y - SettingsManager.shared.cameraHeight
        let denom   = rayWorld.y
        guard abs(denom) > 1e-4 else {
            return (SettingsManager.shared.maxRayDistance, camPos)
        }
        let t = (groundY - camPos.y) / denom
        guard t > 0.05 else {
            return (SettingsManager.shared.maxRayDistance, camPos)
        }
        let intersect = camPos + t * rayWorld
        let dx = intersect.x - camPos.x
        let dz = intersect.z - camPos.z
        let dist = sqrt(dx * dx + dz * dz)
        return (dist, intersect)
    }

    // MARK: - Helpers
    private func clamp(_ d: Float) -> Float {
        return max(SettingsManager.shared.minRayDistance,
                   min(SettingsManager.shared.maxRayDistance, d))
    }

    private func log(_ msg: String) {
        onDebugLog?(msg)
        print("[DetectionManager] \(msg)")
    }
}