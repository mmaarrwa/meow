import Foundation
import CoreML
import CoreImage
import CoreVideo
import UIKit
import ARKit

final class DepthEstimator {
    static let shared = DepthEstimator()

    var onDebugLog: ((String) -> Void)?

    private var model: MLModel?
    private let ciContext = CIContext()
    private let inputWidth  = 518 //fix 518 not 512 ya bakra
    private let inputHeight = 392

    // Busy-guard: if GPU is mid-inference, drop the frame silently
    private var isRunning = false

    // Cache: latest depth buffer + calibration — read by sampleMetricDepth()
    private var cachedDepthBuffer:  CVPixelBuffer?            = nil
    private var cachedCalibration:  (a: Float, b: Float)      = (0.001, 0.0)

    private init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadModel()
        }
    }

    private func loadModel() {
        guard let modelURL = Bundle.main.url(
                forResource: "DepthAnythingV2SmallF16",
                withExtension: "mlmodelc") else {
            onDebugLog?("❌ Depth model not found in bundle")
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU   
            model = try MLModel(contentsOf: modelURL, configuration: config)
            onDebugLog?("✅ Depth model loaded")
        } catch {
            onDebugLog?("❌ Depth model failed to load: \(error)")
        }
    }

    // MARK: - Public: Sample Metric Depth at a Normalised Screen Coordinate
    func sampleMetricDepth(normX: Float, normY: Float) -> Float? {
        guard let buffer = cachedDepthBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let w        = CVPixelBufferGetWidth(buffer)
        let h        = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let ptr            = base.assumingMemoryBound(to: Float16.self)
        let elementsPerRow = rowBytes / MemoryLayout<Float16>.stride
        let px = max(0, min(Int(normX * Float(w)), w - 1))
        let py = max(0, min(Int(normY * Float(h)), h - 1))

        let aiValue = Float(ptr[py * elementsPerRow + px])
        guard aiValue > 0 else { return nil }

        let (a, b) = cachedCalibration
        let calibratedDisparity = a * aiValue + b
        guard calibratedDisparity > 0 else { return nil }
        return 1.0 / calibratedDisparity
    }

    // MARK: - Virtual LiDAR Generator
    func generateVirtualLiDAR(on sourcePixelBuffer: CVPixelBuffer,
                               frame: ARFrame) -> (scan: [Float]?, image: UIImage)? {

        guard !isRunning else { return nil }
        let thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .critical {
            onDebugLog?("🔥 Thermal critical — pausing depth inference")
            return nil
        }
        
        isRunning = true
        defer { isRunning = false }

        guard let model = model else { return nil }

        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer).oriented(.right)
        guard let inputBuffer = resizedPixelBuffer(
                from: sourceImage,
                width: inputWidth,
                height: inputHeight) else { return nil }

        do {
            let inputValue = MLFeatureValue(pixelBuffer: inputBuffer)
            let provider   = try MLDictionaryFeatureProvider(
                                    dictionary: ["image": inputValue])
            let output     = try model.prediction(from: provider)

            guard let depthBuffer = output.featureValue(for: "depth")?
                                          .imageBufferValue else { return nil }

            CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

            let w        = CVPixelBufferGetWidth(depthBuffer)
            let h        = CVPixelBufferGetHeight(depthBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(depthBuffer)
            guard let base = CVPixelBufferGetBaseAddress(depthBuffer) else { return nil }
            let ptr            = base.assumingMemoryBound(to: Float16.self)
            let elementsPerRow = rowBytes / MemoryLayout<Float16>.stride

            // ── 1. DYNAMIC CALIBRATION (Least-Squares in disparity space) ────────
            let pitch        = frame.camera.eulerAngles.x
            // FIX 1: Use the physical mounting height from Settings, not ARKit's 0.0 origin!
            let cameraHeight = Float(SettingsManager.shared.cameraHeight)
            let verticalFOV: Float = 60.0 * .pi / 180.0

            var aiValues:        [Float] = []
            var trueDisparities: [Float] = []

            // FIX 2: Check physical height, but allow flat-mounted phones to calibrate
            if cameraHeight > 0.1 {
                let samplePercents: [Float] = [0.75, 0.80, 0.85, 0.90, 0.95]
                let anchorCol = w / 2
                for percent in samplePercents {
                    let anchorRow        = Int(Float(h) * percent)
                    let aiValue          = Float(ptr[anchorRow * elementsPerRow + anchorCol])
                    let rayPitchOffset   = (percent - 0.5) * verticalFOV
                    let absoluteRayPitch = pitch - rayPitchOffset
                    
                    // If this specific ray hits the floor, calibrate!
                    if absoluteRayPitch < -0.05 && aiValue > 0 {
                        let trueDepth     = abs(cameraHeight / sin(absoluteRayPitch))
                        let trueDisparity = 1.0 / trueDepth
                        aiValues.append(aiValue)
                        trueDisparities.append(trueDisparity)
                    }
                }
            }

            var calibratedScan: [Float]? = nil

            if aiValues.count >= 3, let fit = leastSquaresFit(x: aiValues, y: trueDisparities) {
                let a = fit.a
                let b = fit.b

                // ── Cache for DetectionManager.sampleMetricDepth() ───────────────────
                if cachedDepthBuffer == nil {  // first time only
                    onDebugLog?("🎯 First successful depth calibration: a=\(a), b=\(b)")
                }
                cachedDepthBuffer = depthBuffer
                cachedCalibration = (a, b)

                // ── 2. BUILD 30-COLUMN VIRTUAL LASER SCAN ────────────────────────────
                let settings = SettingsManager.shared
                let cols     = settings.numScanColumns
                let rows     = settings.numScanRows
                let vcOff    = Float(settings.verticalCenterOffset)
                let vSpread  = Float(settings.verticalSpread)
                let hSpread  = Float(settings.horizontalSpread)
                let minD     = settings.minRayDistance
                let maxD     = settings.maxRayDistance

                var virtualScan = Array(repeating: Float(10.0), count: cols)

                for col in 0..<cols {
                    let nx     = (Float(col) / Float(cols - 1) * 2.0 - 1.0) * hSpread
                    let px     = max(0, min(Int((0.5 + nx * 0.5) * Float(w)), w - 1))
                    var colMin = Float(10.0)

                    for row in 0..<rows {
                        let ny    = Float(row) / Float(max(1, rows - 1)) * 2.0 - 1.0
                        let normY = vcOff + ny * vSpread
                        let py    = max(0, min(Int(normY * Float(h)), h - 1))
                        let aiValue = Float(ptr[py * elementsPerRow + px])
                        if aiValue > 0 {
                            let calibratedDisparity = (a * aiValue) + b
                            if calibratedDisparity > 0 {
                                let trueDepth = 1.0 / calibratedDisparity
                                if trueDepth >= minD && trueDepth <= maxD {
                                    colMin = min(colMin, trueDepth)
                                }
                            }
                        }
                    }
                    virtualScan[col] = colMin
                }
                
                // Calibration succeeded, safe to populate the scan array
                calibratedScan = virtualScan
            }

            // ── 3. VISUALISATION (ALWAYS RUNS) ──────────────────────────────────
            let depthImage = normaliseDepthToImage(
                ptr: ptr, w: w, h: h, elementsPerRow: elementsPerRow)

            return (calibratedScan, depthImage)

        } catch {
            onDebugLog?("❌ Virtual LiDAR failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Depth Visualisation Helper
    private func normaliseDepthToImage(ptr: UnsafePointer<Float16>,
                                        w: Int, h: Int,
                                        elementsPerRow: Int) -> UIImage {
        var minVal: Float =  Float.greatestFiniteMagnitude
        var maxVal: Float = -Float.greatestFiniteMagnitude
        for row in 0..<h {
            for col in 0..<w {
                let v = Float(ptr[row * elementsPerRow + col])
                if v.isFinite && v > 0 { minVal = min(minVal, v); maxVal = max(maxVal, v) }
            }
        }
        let range = maxVal - minVal
        guard range > 0 else { return UIImage() }

        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let v    = Float(ptr[row * elementsPerRow + col])
                let norm = UInt8(max(0, min(255, ((v - minVal) / range) * 255)))
                let idx  = (row * w + col) * 4
                pixels[idx]     = norm   // R
                pixels[idx + 1] = norm   // G
                pixels[idx + 2] = norm   // B
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else { return UIImage() }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private func leastSquaresFit(x: [Float], y: [Float]) -> (a: Float, b: Float)? {
        let n = Float(x.count)
        guard n > 1 else { return nil }
        let sumX  = x.reduce(0, +)
        let sumY  = y.reduce(0, +)
        let sumXY = zip(x, y).map(*).reduce(0, +)
        let sumX2 = x.map { $0 * $0 }.reduce(0, +)
        let denom = (n * sumX2) - (sumX * sumX)
        guard denom != 0 else { return nil }
        let a = ((n * sumXY) - (sumX * sumY)) / denom
        let b = (sumY - (a * sumX)) / n
        return (a, b)
    }

    private func resizedPixelBuffer(from ciImage: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey:        true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary,
                            &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        let scaleX = CGFloat(width)  / ciImage.extent.width
        let scaleY = CGFloat(height) / ciImage.extent.height
        ciContext.render(
            ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)),
            to: buffer)
        return buffer
    }
}