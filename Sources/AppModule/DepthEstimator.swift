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
    private let inputWidth  = 518
    private let inputHeight = 392

    // Busy-guard: if GPU is mid-inference, drop the frame silently
    private var isRunning = false

    // Cache: latest depth buffer + calibration — read by sampleMetricDepth()
    // so DetectionManager can look up per-object depth without re-running inference
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
            config.computeUnits = .cpuAndGPU   // bypasses Neural Engine freeze
            model = try MLModel(contentsOf: modelURL, configuration: config)
            onDebugLog?("✅ Depth model loaded")
        } catch {
            onDebugLog?("❌ Depth model failed to load: \(error)")
        }
    }

    // MARK: - Public: Sample Metric Depth at a Normalised Screen Coordinate
    // normX: 0=left,  1=right   (same direction as Vision bbox.midX)
    // normY: 0=top,   1=bottom  (top-left origin — i.e. 1.0 - Vision Y)
    // Called by DetectionManager.mDepth_model for per-object distance.
    // Returns nil if no inference has completed yet.
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
    // Returns (scan: 30-column distance array, image: normalised depth visualisation)
    // or nil if busy or model not ready yet.
    func generateVirtualLiDAR(on sourcePixelBuffer: CVPixelBuffer,
                               frame: ARFrame) -> (scan: [Float], image: UIImage)? {

        guard !isRunning else { return nil }
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
            let cameraHeight = frame.camera.transform.columns.3.y
            let verticalFOV: Float = 60.0 * .pi / 180.0

            var aiValues:        [Float] = []
            var trueDisparities: [Float] = []

            if pitch < -0.1 && cameraHeight > 0.1 {
                let samplePercents: [Float] = [0.75, 0.80, 0.85, 0.90, 0.95]
                let anchorCol = w / 2
                for percent in samplePercents {
                    let anchorRow        = Int(Float(h) * percent)
                    let aiValue          = Float(ptr[anchorRow * elementsPerRow + anchorCol])
                    let rayPitchOffset   = (percent - 0.5) * verticalFOV
                    let absoluteRayPitch = pitch - rayPitchOffset
                    if absoluteRayPitch < -0.05 && aiValue > 0 {
                        let trueDepth     = abs(cameraHeight / sin(absoluteRayPitch))
                        let trueDisparity = 1.0 / trueDepth
                        aiValues.append(aiValue)
                        trueDisparities.append(trueDisparity)
                    }
                }
            }

            var a: Float = 0.001
            var b: Float = 0.0
            if aiValues.count >= 3,
               let fit = leastSquaresFit(x: aiValues, y: trueDisparities) {
                a = fit.a
                b = fit.b
            }

            // ── Cache for DetectionManager.sampleMetricDepth() ───────────────────
            // CVPixelBuffer reference is retained; locking separately when reading
            // is safe because CVPixelBuffer lock/unlock is reference-counted.
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
            var hitCount    = 0

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
                                hitCount += 1
                            }
                        }
                    }
                }
                virtualScan[col] = colMin
            }

            guard hitCount > 0 else { return nil }

            // ── 3. VISUALISATION: normalise Float16 → grayscale UIImage ──────────
            // CIImage cannot auto-display a Float16 single-channel buffer,
            // so we normalise values to 0–255 RGBA explicitly.
            // Brighter = larger raw AI value = typically CLOSER (disparity space).
            let depthImage = normaliseDepthToImage(
                ptr: ptr, w: w, h: h, elementsPerRow: elementsPerRow)

            return (virtualScan, depthImage)

        } catch {
            onDebugLog?("❌ Virtual LiDAR failed: \(error)")
            return nil
        }
    }

    // MARK: - Depth Visualisation Helper
    // Normalises the raw Float16 disparity map to a grayscale UIImage.
    // Bright = high disparity = close. Dark = low disparity = far.
    private func normaliseDepthToImage(ptr: UnsafePointer<Float16>,
                                        w: Int, h: Int,
                                        elementsPerRow: Int) -> UIImage {
        // 1. Find min and max across the whole buffer for normalisation
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

        // 2. Write normalised values into a RGBA byte array
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let v    = Float(ptr[row * elementsPerRow + col])
                let norm = UInt8(max(0, min(255, ((v - minVal) / range) * 255)))
                let idx  = (row * w + col) * 4
                pixels[idx]     = norm   // R
                pixels[idx + 1] = norm   // G
                pixels[idx + 2] = norm   // B
                // pixels[idx + 3] = 255 already set
            }
        }

        // 3. Wrap in a CGImage → UIImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else { return UIImage() }

        // .right orients the depth map to match portrait display
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    // MARK: - Least-Squares Helper
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

    // MARK: - Pixel Buffer Resize Helper
    private func resizedPixelBuffer(from ciImage: CIImage,
                                    width: Int,
                                    height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey:         true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        let scaleX = CGFloat(width)  / ciImage.extent.width
        let scaleY = CGFloat(height) / ciImage.extent.height
        ciContext.render(
            ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)),
            to: buffer)
        return buffer
    }
}