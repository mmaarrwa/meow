import SwiftUI
import ARKit
import ReplayKit // NEW: Required for Screen Recording

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var arManager  = ARManager.shared
    @StateObject private var settings   = SettingsManager.shared
    @State private var showSettings     = false
    @State private var showHeightPrompt = false
    @State private var heightInput      = ""

    // --- State variables for dragging and zooming the depth map ---
    @State private var pipOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var pipScale: CGFloat = 1.0
    @State private var activeScale: CGFloat = 1.0
    // --------------------------------------------------------------
    
    // --- State variables for Thermal State ---
    @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    // -----------------------------------------
    
    // --- State variables for Screen Recording ---
    @State private var isRecording = false
    @State private var showPreview = false
    @State private var previewVC: RPPreviewViewController? = nil
    // --------------------------------------------

    var body: some View {
        ZStack {
            // ── Layer 1: AR Camera Feed ──────────────────────────────
            ARViewContainer(arManager: arManager)
                .edgesIgnoringSafeArea(.all)

            // ── Layer 2: Detection Overlay ───────────────────────────
            DetectionOverlay(
                detections: arManager.currentDetections,
                imageSize:  arManager.lastImageSize,
                screenSize: UIScreen.main.bounds.size
            )
            .edgesIgnoringSafeArea(.all)
            .allowsHitTesting(false)

            // ── Layer 3: HUD ─────────────────────────────────────────
            VStack(spacing: 0) {

                // Top bar
                HStack {
                    Circle()
                        .fill(arManager.isTracking ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(arManager.isTracking ? "Tracking" : "Initializing...")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // --- NEW: Thermal Warning Indicator ---
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer")
                        Text(thermalText)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(thermalColor)
                    .padding(.horizontal, 12)
                    // --------------------------------------
                    
                    // Gear icon → toggle sidebar
                    Button(action: { withAnimation(.easeInOut(duration: 0.25)) {
                        showSettings.toggle()
                    }}) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 18))
                            .padding(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55))

                // Origin marker status bar
                OriginStatusBar(isStreaming:  arManager.isStreaming,
                                isVisible:    arManager.isOriginVisible,
                                data:         arManager.originData)

                Spacer()
                
                // Bottom control panel
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(arManager.isStreaming ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(arManager.isStreaming ? "Streaming @ 10Hz" : "Waiting for START...")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        // --- NEW: Screen Record Button ---
                        Button(action: toggleRecording) {
                            Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                                .font(.system(size: 24))
                                .foregroundColor(isRecording ? .red : .white)
                                .padding(.trailing, 4)
                        }
                        // ---------------------------------
                        
                        // Start/Stop button 
                        Button(action: {
                            if arManager.isStreaming {
                                arManager.stopStreaming()
                            } else {
                                arManager.startStreaming()
                            }
                        }) {
                            Text(arManager.isStreaming ? "STOP" : "START")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(arManager.isStreaming ? Color.red : Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "wifi").foregroundColor(.gray).frame(width: 18)
                        TextField("Laptop IP", text: $settings.serverIP)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .keyboardType(.decimalPad)
                            .padding(7)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(6)
                            .foregroundColor(.white)
                        Button(action: {
                            hideKeyboard()
                            if arManager.isConnected {
                                arManager.disconnectFromNetwork()
                            } else {
                                arManager.connectToNetwork()
                            }
                        }) {
                            Text(arManager.isConnected ? "Disconnect" : "Connect")
                                .font(.caption.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(arManager.isConnected ? Color.red : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                    }
                    if !arManager.currentDetections.isEmpty {
                        Text("\(arManager.currentDetections.count) object(s) detected")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .padding(14)
                .background(Color.black.opacity(0.80))
                .cornerRadius(16)
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .shadow(radius: 8)
            }

            // ── Layer 4: AI DEPTH MAP VISUALIZER (DRAGGABLE & ZOOMABLE) ───────
            if arManager.isStreaming, let depthImage = arManager.depthMapImage {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(uiImage: depthImage)
                            .resizable()
                            .scaledToFit()
                            // NEW: Multiply base width by our zoom scale
                            .frame(width: max(80, 140 * (pipScale * activeScale)))
                            .border(Color.cyan.opacity(0.8), width: 2)
                            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                            .padding(.bottom, 160)
                            .padding(.trailing, 20)
                            .offset(x: pipOffset.width + dragOffset.width,
                                    y: pipOffset.height + dragOffset.height)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        dragOffset = value.translation
                                    }
                                    .onEnded { value in
                                        pipOffset.width += value.translation.width
                                        pipOffset.height += value.translation.height
                                        dragOffset = .zero
                                    }
                            )
                            // NEW: Add Pinch-to-Zoom Gesture
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        activeScale = value
                                    }
                                    .onEnded { value in
                                        pipScale *= value
                                        activeScale = 1.0
                                    }
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // ── Layer 5: Settings Sidebar (right side overlay) ───────
            if showSettings {
                HStack {
                    Spacer()
                    SettingsSidebar(isVisible: $showSettings)
                        .frame(width: 290)
                        .transition(.move(edge: .trailing))
                }
                .edgesIgnoringSafeArea(.all)
            }
        }
        .onAppear {
            if settings.cameraHeight > 0 {
                arManager.startSessionIfNeeded()
            } else {
                showHeightPrompt = true
            }
        }
        // --- NEW: Thermal State Listener ---
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
        // -----------------------------------
        .sheet(isPresented: $showHeightPrompt, onDismiss: {
            arManager.startSessionIfNeeded()
        }) {
            HeightInputView(heightInput: $heightInput,
                            isPresented: $showHeightPrompt)
        }
        // --- NEW: Screen Recording Sheet ---
        .sheet(isPresented: $showPreview) {
            if let previewVC = previewVC {
                RPPreviewView(previewController: previewVC, isPresented: $showPreview)
            }
        }
        // -----------------------------------
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    // MARK: - ReplayKit Recording Logic
    private func toggleRecording() {
        let recorder = RPScreenRecorder.shared()
        
        if isRecording {
            recorder.stopRecording { preview, error in
                DispatchQueue.main.async {
                    self.isRecording = false
                    if let preview = preview {
                        self.previewVC = preview
                        self.showPreview = true
                    } else if let error = error {
                        print("Screen recording stop error: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Start recording
            guard recorder.isAvailable else { return }
            recorder.startRecording { error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Screen recording start error: \(error.localizedDescription)")
                    } else {
                        self.isRecording = true
                    }
                }
            }
        }
    }
    
    // MARK: - Thermal State Helpers
    private var thermalColor: Color {
        switch thermalState {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
    
    private var thermalText: String {
        switch thermalState {
        case .nominal:  return "NORMAL"
        case .fair:     return "WARM"
        case .serious:  return "HOT"
        case .critical: return "CRITICAL"
        @unknown default: return "UNKNOWN"
        }
    }
}

// MARK: - ReplayKit View Representable
struct RPPreviewView: UIViewControllerRepresentable {
    let previewController: RPPreviewViewController
    @Binding var isPresented: Bool

    class Coordinator: NSObject, RPPreviewViewControllerDelegate {
        var parent: RPPreviewView
        init(_ parent: RPPreviewView) { self.parent = parent }
        func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
            parent.isPresented = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> RPPreviewViewController {
        previewController.previewControllerDelegate = context.coordinator
        previewController.modalPresentationStyle = .fullScreen
        return previewController
    }

    func updateUIViewController(_ uiViewController: RPPreviewViewController, context: Context) {}
}

// MARK: - Settings Sidebar
struct SettingsSidebar: View {
    @Binding var isVisible: Bool
    @StateObject private var settings = SettingsManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).edgesIgnoringSafeArea(.all)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Header
                    HStack {
                        Text("Settings")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: { withAnimation { isVisible = false } }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .font(.system(size: 20))
                        }
                    }
                    .padding(.top, 60)

                    Divider().background(Color.gray.opacity(0.4))

                    // ── Camera Height ────────────────────────────────
                    SectionHeader("Camera Height")
                    HStack {
                        Slider(value: $settings.cameraHeight, in: 0.1...2.5, step: 0.05)
                            .accentColor(.yellow)
                        Text(String(format: "%.2f m", settings.cameraHeight))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.yellow)
                            .frame(width: 52)
                    }
                    HStack(spacing: 8) {
                        ForEach(["0.8", "1.0", "1.2", "1.5"], id: \.self) { p in
                            Button(p) { settings.cameraHeight = Float(p)! }
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(abs(settings.cameraHeight - Float(p)!) < 0.01
                                    ? Color.yellow : Color.white.opacity(0.15))
                                .foregroundColor(abs(settings.cameraHeight - Float(p)!) < 0.01
                                    ? .black : .white)
                                .cornerRadius(12)
                        }
                    }

                    Divider().background(Color.gray.opacity(0.4))

                    // ── Laser Scan ───────────────────────────────────
                    SectionHeader("Laser Scan (System B)")

                    SettingsRow(label: "Columns") {
                        Picker("", selection: $settings.numScanColumns) {
                            Text("10").tag(10)
                            Text("20").tag(20)
                            Text("30").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .colorMultiply(.cyan)
                    }

                    SettingsRow(label: "Rows/col") {
                        Picker("", selection: $settings.numScanRows) {
                            Text("3").tag(3)
                            Text("5").tag(5)
                            Text("7").tag(7)
                        }
                        .pickerStyle(.segmented)
                        .colorMultiply(.cyan)
                    }

                    SettingsRow(label: "V-center") {
                        VStack(spacing: 2) {
                            Slider(value: $settings.verticalCenterOffset,
                                   in: 0.3...0.8, step: 0.05)
                                .accentColor(.cyan)
                            Text(String(format: "%.2f", settings.verticalCenterOffset))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                    }

                    SettingsRow(label: "V-spread") {
                        VStack(spacing: 2) {
                            Slider(value: $settings.verticalSpread,
                                   in: 0.05...0.4, step: 0.05)
                                .accentColor(.cyan)
                            Text(String(format: "%.2f", settings.verticalSpread))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                    }

                    SettingsRow(label: "H-spread") {
                        VStack(spacing: 2) {
                            Slider(value: $settings.horizontalSpread,
                                   in: 0.2...1.0, step: 0.05)
                                .accentColor(.cyan)
                            Text(String(format: "%.2f", settings.horizontalSpread))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                    }

                    SettingsRow(label: "Max dist") {
                        Picker("", selection: $settings.maxRayDistance) {
                            Text("1m").tag(Float(1.0))
                            Text("3m").tag(Float(3.0))
                            Text("5m").tag(Float(5.0))
                            Text("10m").tag(Float(10.0))
                        }
                        .pickerStyle(.segmented)
                        .colorMultiply(.cyan)
                    }
                    
                    SettingsRow(label: "Smoothing") {
                        VStack(spacing: 2) {
                            Slider(value: $settings.smoothingAlpha,
                                   in: 0.1...1.0, step: 0.1)
                                .accentColor(.cyan)
                            Text(String(format: "%.1f (1.0 = Off)", settings.smoothingAlpha))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.cyan)
                        }
                    }

                    SettingsRow(label: "Ghost Filter") {
                        Picker("", selection: $settings.maxMissTolerance) {
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("3").tag(3)
                            Text("5").tag(5)
                        }
                        .pickerStyle(.segmented)
                        .colorMultiply(.cyan)
                    }

                    Divider().background(Color.gray.opacity(0.4))

                    // ── Debug Visuals ────────────────────────────────
                    SectionHeader("Debug Visuals")

                    Toggle("Show AR Planes", isOn: $settings.showDebugPlanes)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .tint(.cyan)
                        .padding(.vertical, 4)

                    Toggle("Show LiDAR Mesh", isOn: $settings.showDebugMesh)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .tint(.cyan)
                        .padding(.vertical, 4)

                    Divider().background(Color.gray.opacity(0.4))

                    // ── Detection ────────────────────────────────────
                    SectionHeader("Detection (System A)")

                    SettingsRow(label: "Confidence") {
                        VStack(spacing: 2) {
                            Slider(value: $settings.confidenceThreshold,
                                   in: 0.1...0.9, step: 0.05)
                                .accentColor(.green)
                            Text(String(format: "%.0f%%",
                                        settings.confidenceThreshold * 100))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Sidebar Helper Views
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.gray)
            .textCase(.uppercase)
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content
    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
            content
        }
    }
}

// MARK: - Origin Status Bar
struct OriginStatusBar: View {
    let isStreaming: Bool
    let isVisible:  Bool
    let data:       OriginMarkerData?
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isVisible ? Color.cyan : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
            if !isStreaming {
                Text("Origin: press START to activate")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
            } else if let d = data {
                if isVisible {
                    Text(String(format: "Origin ↗ %.2fm  %.1f°",
                                d.distanceMeters, d.bearingRadians * 180 / .pi))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                } else {
                    Text(String(format: "Origin: last %.2fm (not in view)", d.distanceMeters))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }
            } else {
                Text("Origin marker: not yet detected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(Color.black.opacity(0.50))
    }
}

// MARK: - Height Input Sheet (first launch only)
struct HeightInputView: View {
    @Binding var heightInput: String
    @Binding var isPresented: Bool
    @StateObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "camera.metering.center.weighted")
                .font(.system(size: 52)).foregroundColor(.blue)
            Text("Camera Height")
                .font(.system(size: 28, weight: .bold))
            Text("Enter the height of your phone above the ground.\nUsed for distance estimation.")
                .font(.system(size: 15)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                ForEach(["0.8", "1.0", "1.2", "1.5"], id: \.self) { p in
                    Button(action: { heightInput = p }) {
                        Text("\(p) m")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(heightInput == p ? Color.blue : Color(.systemGray5))
                            .foregroundColor(heightInput == p ? .white : .primary)
                            .cornerRadius(20)
                    }
                }
            }
            TextField("e.g. 1.20", text: $heightInput)
                .keyboardType(.decimalPad)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 160)
                .font(.system(size: 18, design: .monospaced))
                .multilineTextAlignment(.center)
            Button(action: {
                let raw = heightInput.replacingOccurrences(of: ",", with: ".")
                if let h = Float(raw), h > 0.1, h < 3.0 {
                    settings.cameraHeight = h
                    isPresented = false
                }
            }) {
                Text("Confirm")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity).padding()
                    .background(canConfirm ? Color.blue : Color.gray)
                    .foregroundColor(.white).cornerRadius(14)
                    .padding(.horizontal, 40)
            }
            .disabled(!canConfirm)
            Spacer()
        }
        .padding()
    }

    private var canConfirm: Bool {
        let raw = heightInput.replacingOccurrences(of: ",", with: ".")
        if let h = Float(raw) { return h > 0.1 && h < 3.0 }
        return false
    }
}

// MARK: - AR View Container
struct ARViewContainer: UIViewRepresentable {
    var arManager: ARManager
    func makeUIView(context: Context) -> ARSCNView { arManager.sceneView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Detection Overlay
struct DetectionOverlay: View {
    let detections: [DetectedObject]
    let imageSize:  CGSize
    let screenSize: CGSize

    var body: some View {
        Canvas { context, size in
            for det in detections {
                let rect = projectBoundingBox(det.normalizedRect,
                                              imageSize: imageSize, screenSize: size)
                guard rect.width > 0, rect.height > 0 else { continue }
                let color = classColor(det.label)
                var path = Path(); path.addRect(rect)
                context.stroke(path, with: .color(color), lineWidth: 2.5)

                let label = "\(det.label) \(String(format: "%.1f", det.distanceMeters))m [\(det.distanceMethod)]"
                let fontSize: CGFloat = 13; let pad: CGFloat = 5
                let ts = labelTextSize(label, fontSize: fontSize)
                let lr = CGRect(x: rect.minX,
                                y: max(0, rect.minY - ts.height - pad * 2),
                                width: ts.width + pad * 2,
                                height: ts.height + pad * 2)
                var bg = Path()
                bg.addRoundedRect(in: lr, cornerSize: CGSize(width: 4, height: 4))
                context.fill(bg, with: .color(color))
                context.draw(
                    Text(label)
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white),
                    at: CGPoint(x: lr.minX + pad, y: lr.minY + pad),
                    anchor: .topLeading)
            }
        }
    }

    private func projectBoundingBox(_ n: CGRect, imageSize: CGSize, screenSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let f = CGRect(x: n.origin.x, y: 1.0 - n.origin.y - n.height,
                       width: n.width, height: n.height)
        return CGRect(x: f.origin.x * screenSize.width, y: f.origin.y * screenSize.height,
                      width: f.width * screenSize.width, height: f.height * screenSize.height)
    }

    private func classColor(_ label: String) -> Color {
        let colors: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .yellow, .cyan]
        return colors[abs(label.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % colors.count]
    }

    private func labelTextSize(_ text: String, fontSize: CGFloat) -> CGSize {
        (text as NSString).size(withAttributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)])
    }
}