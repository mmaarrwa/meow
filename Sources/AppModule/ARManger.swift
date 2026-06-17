import Foundation
import ARKit
import SceneKit
import simd
import SwiftUI
import Combine

final class ARManager: NSObject, ObservableObject {
    static let shared = ARManager()

    // MARK: - Published State
    @Published var isTracking:    Bool  = false
    @Published var isStreaming:   Bool  = false
    @Published var currentDetections: [DetectedObject] = []
    @Published var lastImageSize: CGSize = CGSize(width: 1920, height: 1440)
    @Published var isOriginVisible: Bool = false
    @Published var originData: OriginMarkerData? = nil
    @Published var isConnected:   Bool  = false

    // MARK: - AR Scene View
    let sceneView: ARSCNView = {
        let v = ARSCNView(frame: .zero)
        v.autoenablesDefaultLighting = true
        v.debugOptions = [ARSCNDebugOptions.showFeaturePoints]
        v.rendersContinuously = true
        return v
    }()

    // MARK: - Private
    private let network  = NetworkManager.shared
    private let settings = SettingsManager.shared
    private var scanTimer: Timer?

    // MARK: - Combine
    private var cancellables = Set<AnyCancellable>()

    // Detection smoothing
    private var detectionHistory: [[DetectedObject]] = []
    private let historyLength = 2

    // Laser scan smoothing — sized dynamically from settings
    private var smoothedScan: [Float] = []
    private var missCounters: [Int] = []

    private var hasRunDepthSmokeTest = false

    // MARK: - Init
    override init() {
        super.init()

        //send the 3d updates
        sceneView.delegate = self

        DetectionManager.shared.sceneView = sceneView

        DetectionManager.shared.onDebugLog = { [weak self] msg in
            self?.network.sendLog(msg)
        }
        OriginMarkerManager.shared.onDebugLog = { [weak self] msg in
            self?.network.sendLog(msg)
        }

        DetectionManager.shared.onDetections = { [weak self] detections, imageSize in
            guard let self = self else { return }
            self.lastImageSize   = imageSize
            self.currentDetections = self.smoothDetections(detections)
        }

        OriginMarkerManager.shared.onMarkerUpdated = { [weak self] data in
            guard let self = self else { return }
            self.originData      = data
            self.isOriginVisible = OriginMarkerManager.shared.isVisible
        }

        DepthEstimator.shared.onDebugLog = { [weak self] msg in
            self?.network.sendLog(msg)
        }

        network.onCommandReceived = { [weak self] command in
            self?.handleRemoteCommand(command)
        }

        network.onStateChanged = { [weak self] connected in
            DispatchQueue.main.async {
                self?.isConnected = connected
            }
        }

        // Listen for LiDAR Mesh Toggle
        settings.$showDebugMesh.sink { [weak self] show in
            DispatchQueue.main.async { self?.updateDebugOptions(showMesh: show) }
        }.store(in: &cancellables)

        // Listen for Plane Toggle (Hide/Show existing planes instantly)
        settings.$showDebugPlanes.sink { [weak self] show in
            DispatchQueue.main.async {
                self?.sceneView.scene.rootNode.enumerateChildNodes { (node, _) in
                    if node.name == "DebugPlane" { node.isHidden = !show }
                }
            }
        }.store(in: &cancellables)

    }

    private func updateDebugOptions(showMesh: Bool) {
        // 1. Feature points are always on
        sceneView.debugOptions = [.showFeaturePoints]
        
        // 2. Instantly hide/show the manual LiDAR mesh we built in the delegate
        sceneView.scene.rootNode.enumerateChildNodes { (node, _) in
            if node.name == "DebugMesh" { 
                node.isHidden = !showMesh 
            }
        }
    }

    // MARK: - Session Management

    /// Called on app open — starts camera but does NOT reset origin
    func startSessionIfNeeded() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let config = buildConfig()
        sceneView.session.delegate = self
        sceneView.session.run(config)
        network.sendLog("📱 App opened — waiting for START")
    }

    func connectToNetwork() {
        network.start(ipAddress: settings.serverIP)
        network.sendLog("📡 Connected — waiting for START command")
    }

    func disconnectFromNetwork() {
        // Safety check: if they disconnect while the robot is driving, stop streaming first!
        if isStreaming { 
            stopStreaming() 
        }
        network.stop() // Stops the UDP socket
        isConnected = false // Tell the UI we disconnected
    }

    private func handleRemoteCommand(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        DispatchQueue.main.async {
            if cmd == "START" && !self.isStreaming { self.startStreaming() }
            else if cmd == "STOP" && self.isStreaming { self.stopStreaming() }
        }
    }

    func startStreaming() {
        isStreaming = true

        // Reset origin marker — discard any pre-START sightings
        OriginMarkerManager.shared.isActive = false
        OriginMarkerManager.shared.isActive = true

        // Reset ARKit — current position becomes (0,0,0)
        let config = buildConfig()
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Safely resize arrays based on current UI setting
        let cols = settings.numScanColumns
        smoothedScan = Array(repeating: 10.0, count: cols)
        missCounters = Array(repeating: 0, count: cols)

        // One Timer drives everything at 10Hz on main thread
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.1,
                                          repeats: true) { [weak self] _ in
            self?.tick()
        }

        network.sendLog("▶️ START — ARKit origin reset")
    }

    func stopStreaming() {
        isStreaming = false
        scanTimer?.invalidate()
        scanTimer = nil
        OriginMarkerManager.shared.isActive = false
        network.sendLog("⏹ STOP")
    }

    // MARK: - Config Builder
    private func buildConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment  = .gravity
        config.planeDetection  = [.horizontal, .vertical]

        let refImages = OriginMarkerManager.shared.referenceImages()
        if !refImages.isEmpty {
            config.detectionImages              = refImages
            config.maximumNumberOfTrackedImages = 1
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        return config
    }

    // MARK: - Main Tick (10Hz, main thread)
    // Everything that needs main thread runs here directly.
    // YOLO inference dispatched to background.
    private func tick() {
        guard let frame = sceneView.session.currentFrame else { return }

        // Update tracking status
        isTracking = frame.camera.trackingState == .normal

        
        // inside tick(), anywhere after `frame` is unwrapped:
        if !hasRunDepthSmokeTest {
            hasRunDepthSmokeTest = true
            DepthEstimator.shared.runSmokeTest(on: frame.capturedImage)
        }

        // ── System B: Laser Scan ────────────────────────────────────
        let (scanArray, confidence, scanMethod) = getLaserScan(frame: frame)
        let cols = settings.numScanColumns
        if smoothedScan.count != cols {
            smoothedScan = Array(repeating: 10.0, count: cols)
            missCounters = Array(repeating: 0, count: cols)
        }
        let alpha = settings.smoothingAlpha
        let maxMissTolerance = settings.maxMissTolerance
        for i in 0..<cols {
            if scanArray[i] < 9.9 {
                // STATE 1: REAL HIT (Obstacle Detected)
                if smoothedScan[i] >= 9.9 {
                    // Instant snap on new obstacle appearance!
                    smoothedScan[i] = scanArray[i] 
                } else {
                    // Standard noise smoothing for existing obstacles
                    smoothedScan[i] = (alpha * scanArray[i]) + ((1.0 - alpha) * smoothedScan[i])
                }
                missCounters[i] = 0 // Reset miss counter because we saw something!
                
            } else {
                // STATE 2 & 3: MISS (Looking at empty space)
                missCounters[i] += 1
                
                if missCounters[i] >= maxMissTolerance {
                    // STATE 3: CONFIRMED CLEAR
                    smoothedScan[i] = 10.0
                } 
            }
        }

        // ── System A: YOLO — dispatch to background ─────────────────
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            DetectionManager.shared.processFrame(frame)
        }

        // ── Build and send state packet ─────────────────────────────
        sendStatePacket(frame: frame,
                        scan: smoothedScan,
                        scanMethod: scanMethod,
                        scanConfidence: confidence)
    }

    // MARK: - State Packet
    private func sendStatePacket(frame:           ARFrame,
                                  scan:            [Float],
                                  scanMethod:      String,
                                  scanConfidence:  Float) {
        let cam = frame.camera.transform
        let pos = cam.columns.3
        let q   = simd_quatf(cam)

        // Detections with world XYZ
        let detectionsJSON: [[String: Any]] = currentDetections.map { det in
            let bearing = atan2f(det.worldPosition.x - pos.x,
                                  det.worldPosition.z - pos.z)
            return [
                "label":          det.label,
                "confidence":     det.confidence,
                "world_position": [det.worldPosition.x,
                                   det.worldPosition.y,
                                   det.worldPosition.z],
                "distance":       det.distanceMeters,
                "bearing":        bearing,
                "method":         det.distanceMethod
            ]
        }

        // Origin marker
        var originJSON: [String: Any] = ["detected": false]
        if let od = originData, OriginMarkerManager.shared.isVisible {
            originJSON = [
                "detected":       true,
                "world_position": [od.worldPosition.x,
                                   od.worldPosition.y,
                                   od.worldPosition.z],
                "distance":       od.distanceMeters,
                "bearing":        od.bearingRadians
            ]
        }

        let packet: [String: Any] = [
            "type":             "state",
            "timestamp":        frame.timestamp,
            "position":         [pos.x, pos.y, pos.z],
            "orientation":      [q.vector.x, q.vector.y,
                                  q.vector.z, q.vector.w],
            "laser_scan":       scan,
            "scan_method":      scanMethod,
            "scan_confidence":  scanConfidence,
            "detections":       detectionsJSON,
            "origin_marker":    originJSON
        ]
        network.sendPose(packet)
    }

    // MARK: - System B: Laser Scan Cascade
    // Runs on main thread (called from tick)
    private func getLaserScan(frame: ARFrame)
        -> (distances: [Float], confidence: Float, method: String) {

        if let d = m1_lidarScan(frame: frame)   { return (d, 1.0, "M1_LiDAR")   }
        if let d = m2_raycastScan(frame: frame)  { return (d, 0.8, "M2_Raycast") }
        if let d = m3_hitTestScan(frame: frame)  { return (d, 0.5, "M3_HitTest") }
        return (m4_coneScan(frame: frame),         0.2, "M4_Cone")
    }

    // MARK: - M1: LiDAR scan
    private func m1_lidarScan(frame: ARFrame) -> [Float]? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w   = CVPixelBufferGetWidth(depthMap)
        let h   = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let buf = base.assumingMemoryBound(to: Float32.self)

        let cols   = settings.numScanColumns
        let rows   = settings.numScanRows
        let vcOff  = Float(settings.verticalCenterOffset)
        let vSpread = Float(settings.verticalSpread)
        let hSpread = Float(settings.horizontalSpread)
        let minD   = settings.minRayDistance
        let maxD   = settings.maxRayDistance

        var scan     = Array(repeating: Float(10.0), count: cols)
        var hitCount = 0

        for col in 0..<cols {
            let nx = (Float(col) / Float(cols - 1) * 2.0 - 1.0) * hSpread
            let px = max(0, min(Int((0.5 + nx * 0.5) * Float(w)), w - 1))
            var colMin = Float(10.0)

            for row in 0..<rows {
                let ny   = Float(row) / Float(max(1, rows - 1)) * 2.0 - 1.0
                let normY = vcOff + ny * vSpread
                let py   = max(0, min(Int(normY * Float(h)), h - 1))
                let d    = buf[py * w + px]
                if d >= minD && d <= maxD {
                    colMin = min(colMin, d)
                    hitCount += 1
                }
            }
            scan[col] = colMin
        }
        return hitCount > 0 ? scan : nil
    }

    // MARK: - M2: Raycast scan (main thread — called from tick directly)
    private func m2_raycastScan(frame: ARFrame) -> [Float]? {
        let view   = sceneView
        let bounds = view.bounds
        guard bounds.width > 0 else { return nil }

        let cols    = settings.numScanColumns
        let rows    = settings.numScanRows
        let vcOff   = settings.verticalCenterOffset
        let vSpread = settings.verticalSpread
        let hSpread = CGFloat(settings.horizontalSpread)
        let minD    = settings.minRayDistance
        let maxD    = settings.maxRayDistance
        let camPos  = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                    frame.camera.transform.columns.3.y,
                                    frame.camera.transform.columns.3.z)

        var scan     = Array(repeating: Float(10.0), count: cols)
        var hitCount = 0

        for col in 0..<cols {
            let nx = (CGFloat(col) / CGFloat(cols - 1) * 2.0 - 1.0) * hSpread
            var colMin = Float(10.0)

            for row in 0..<rows {
                let ny = CGFloat(row) / CGFloat(max(1, rows - 1)) * 2.0 - 1.0
                let pt = CGPoint(
                    x: bounds.midX + nx * (0.5 * bounds.width),
                    y: bounds.height * (vcOff + Double(ny) * vSpread)
                )

                for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
                    guard let query = view.raycastQuery(from: pt,
                                                        allowing: target,
                                                        alignment: .any) else { continue }
                    if let hit = view.session.raycast(query).first {
                        let hp = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                              hit.worldTransform.columns.3.y,
                                              hit.worldTransform.columns.3.z)
                        let d = simd_length(hp - camPos)
                        if d >= minD && d <= maxD {
                            colMin = min(colMin, d); hitCount += 1
                        }
                        break
                    }
                }
            }
            scan[col] = colMin
        }
        return hitCount > 0 ? scan : nil
    }

    // MARK: - M3: HitTest scan (main thread — called from tick directly)
    private func m3_hitTestScan(frame: ARFrame) -> [Float]? {
        let view   = sceneView
        let bounds = view.bounds
        guard bounds.width > 0 else { return nil }

        let cols    = settings.numScanColumns
        let rows    = settings.numScanRows
        let vcOff   = settings.verticalCenterOffset
        let vSpread = settings.verticalSpread
        let hSpread = CGFloat(settings.horizontalSpread)
        let minD    = settings.minRayDistance
        let maxD    = settings.maxRayDistance
        let camPos  = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                    frame.camera.transform.columns.3.y,
                                    frame.camera.transform.columns.3.z)

        var scan     = Array(repeating: Float(10.0), count: cols)
        var hitCount = 0

        for col in 0..<cols {
            let nx = (CGFloat(col) / CGFloat(cols - 1) * 2.0 - 1.0) * hSpread
            var colMin = Float(10.0)

            for row in 0..<rows {
                let ny = CGFloat(row) / CGFloat(max(1, rows - 1)) * 2.0 - 1.0
                let pt = CGPoint(
                    x: bounds.midX + nx * (0.5 * bounds.width),
                    y: bounds.height * (vcOff + Double(ny) * vSpread)
                )
                if let hit = view.hitTest(pt, types: [.featurePoint,
                                                       .existingPlaneUsingExtent,
                                                       .estimatedHorizontalPlane]).first {
                    // --- DEBUG ADDITION START ---
                    // Draw a tiny red dot where the HitTest found a feature point
                    /*let debugNode = SCNNode(geometry: SCNSphere(radius: 0.02))
                    debugNode.geometry?.firstMaterial?.diffuse.contents = UIColor.red
                    debugNode.position = SCNVector3(hit.worldTransform.columns.3.x,
                                                    hit.worldTransform.columns.3.y,
                                                    hit.worldTransform.columns.3.z)
                    debugNode.name = "DebugHitPoint"
                    view.scene.rootNode.addChildNode(debugNode)
                    
                    // Remove the dot after 0.1 seconds so the screen doesn't fill up
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        debugNode.removeFromParentNode()
                    }*/
                    // --- DEBUG ADDITION END ---
                    
                    let hp = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                          hit.worldTransform.columns.3.y,
                                          hit.worldTransform.columns.3.z)
                    let d = simd_length(hp - camPos)
                    if d >= minD && d <= maxD {
                        colMin = min(colMin, d); hitCount += 1
                    }
                }
            }
            scan[col] = colMin
        }
        return hitCount > 0 ? scan : nil
    }

    // MARK: - M4: Feature point cone scan
    private func m4_coneScan(frame: ARFrame) -> [Float] {
        guard let points = frame.rawFeaturePoints?.points else {
            return Array(repeating: 10.0, count: settings.numScanColumns)
        }
        let worldToCam = frame.camera.transform.inverse
        let cols       = settings.numScanColumns
        let minD       = settings.minRayDistance
        let maxD       = settings.maxRayDistance

        var scan = Array(repeating: Float(10.0), count: cols)

        for p in points {
            let local = simd_mul(worldToCam, simd_float4(p.x, p.y, p.z, 1))
            let absZ  = -local.z
            guard absZ > 0.2 && absZ < Float(maxD) else { continue }

            // Map X position to column index
            let angle   = atan2f(local.x, absZ)
            let maxAngle = Float.pi / 3.0   // ±60° coverage
            guard abs(angle) < maxAngle else { continue }

            let normAngle = (angle + maxAngle) / (2.0 * maxAngle)
            let col = max(0, min(Int(normAngle * Float(cols)), cols - 1))
            let d   = max(minD, min(maxD, absZ))
            if d < scan[col] { scan[col] = d }
        }
        return scan
    }

    // MARK: - Detection Smoothing
    private func smoothDetections(_ new: [DetectedObject]) -> [DetectedObject] {
        detectionHistory.append(new)
        if detectionHistory.count > historyLength { detectionHistory.removeFirst() }
        return new.map { det in
            var distances: [Float] = [det.distanceMeters]
            for past in detectionHistory.dropLast() {
                if let match = past.first(where: {
                    $0.label == det.label && iouOverlap($0.normalizedRect, det.normalizedRect) > 0.3
                }) { distances.append(match.distanceMeters) }
            }
            let avg = distances.reduce(0, +) / Float(distances.count)
            return DetectedObject(label:          det.label,
                                  confidence:     det.confidence,
                                  normalizedRect: det.normalizedRect,
                                  distanceMeters: avg,
                                  distanceMethod: det.distanceMethod,
                                  worldPosition:  det.worldPosition)
        }
    }

    private func iouOverlap(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let iA = Float(inter.width * inter.height)
        let uA = Float(a.width * a.height + b.width * b.height) - iA
        return uA > 0 ? iA / uA : 0
    }
}

// MARK: - ARSessionDelegate
extension ARManager: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Tracking status updated in tick() — nothing else needed here
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let frame = session.currentFrame else { return }
        for anchor in anchors {
            OriginMarkerManager.shared.handleAnchorAdded(anchor, frame: frame)
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let frame = session.currentFrame else { return }
        for anchor in anchors {
            OriginMarkerManager.shared.handleAnchorUpdated(anchor, frame: frame)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        network.sendLog("❌ ARSession failed: \(error.localizedDescription)")
        DispatchQueue.main.async { self.isTracking = false }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.isTracking = false }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        sceneView.session.run(buildConfig())
    }
}


// MARK: - ARSCNViewDelegate (Handles Plane & Mesh Rendering)
extension ARManager: ARSCNViewDelegate {
    
    // When ARKit finds a new plane OR a new LiDAR mesh chunk
    // When ARKit finds a new plane OR a new LiDAR mesh chunk
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        let node = SCNNode()
        
        // 1. Handle Planes
        if let planeAnchor = anchor as? ARPlaneAnchor {
            let plane = SCNPlane(width: CGFloat(planeAnchor.planeExtent.width), 
                                 height: CGFloat(planeAnchor.planeExtent.height))
            
            // FIX: Explicitly create a glowing material
            let material = SCNMaterial()
            let color = planeAnchor.alignment == .horizontal ? UIColor.blue : UIColor.orange
            material.diffuse.contents = color.withAlphaComponent(0.6) // Made it slightly less transparent
            material.lightingModel = .constant // Makes it glow like neon regardless of shadows
            material.isDoubleSided = true      // Lets you see it from underneath
            plane.materials = [material]
            
            let planeNode = SCNNode(geometry: plane)
            planeNode.position = SCNVector3(planeAnchor.center.x, 0, planeAnchor.center.z)
            planeNode.eulerAngles.x = -.pi / 2
            planeNode.name = "DebugPlane"
            planeNode.isHidden = !settings.showDebugPlanes
            
            node.addChildNode(planeNode)
        }
        
        // 2. Handle LiDAR Mesh Chunks
        else if let meshAnchor = anchor as? ARMeshAnchor {
            let geometry = SCNGeometry(arGeometry: meshAnchor.geometry)
            
            // Create a wireframe material
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.cyan.withAlphaComponent(0.8)
            material.fillMode = .lines // Draws the matrix-style wireframe
            material.lightingModel = .constant // Glows in the dark
            material.isDoubleSided = true
            geometry.materials = [material]
            
            let meshNode = SCNNode(geometry: geometry)
            meshNode.name = "DebugMesh"
            meshNode.isHidden = !settings.showDebugMesh
            
            node.addChildNode(meshNode)
        }
        
        return node
    }

    // When ARKit refines the size of an existing plane or mesh
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor,
           let planeNode = node.childNodes.first(where: { $0.name == "DebugPlane" }),
           let plane = planeNode.geometry as? SCNPlane {
            
            // FIXED: iOS 16 planeExtent
            plane.width = CGFloat(planeAnchor.planeExtent.width)
            plane.height = CGFloat(planeAnchor.planeExtent.height)
            planeNode.position = SCNVector3(planeAnchor.center.x, 0, planeAnchor.center.z)
            planeNode.isHidden = !settings.showDebugPlanes
        }
        
        else if let meshAnchor = anchor as? ARMeshAnchor,
                let meshNode = node.childNodes.first(where: { $0.name == "DebugMesh" }) {
            
            // Replace the old mesh geometry with the newly refined one
            let newGeometry = SCNGeometry(arGeometry: meshAnchor.geometry)
            newGeometry.materials = meshNode.geometry?.materials ?? []
            meshNode.geometry = newGeometry
            meshNode.isHidden = !settings.showDebugMesh
        }
    }
}

// MARK: - ARMeshGeometry to SCNGeometry Bridge
extension SCNGeometry {
    convenience init(arGeometry: ARMeshGeometry) {
        let verticesSource = SCNGeometrySource(buffer: arGeometry.vertices.buffer, 
                                               vertexFormat: arGeometry.vertices.format, 
                                               semantic: .vertex, 
                                               vertexCount: arGeometry.vertices.count, 
                                               dataOffset: arGeometry.vertices.offset, 
                                               dataStride: arGeometry.vertices.stride)
        
        let facesElement = SCNGeometryElement(buffer: arGeometry.faces.buffer, 
                                              primitiveType: .triangles, 
                                              primitiveCount: arGeometry.faces.count, 
                                              bytesPerIndex: arGeometry.faces.bytesPerIndex)
        
        self.init(sources: [verticesSource], elements: [facesElement])
    }
}


