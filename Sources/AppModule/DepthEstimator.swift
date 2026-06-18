import Foundation
import CoreML
import CoreImage
import CoreVideo
import UIKit

final class DepthEstimator {
    static let shared = DepthEstimator()

    var onDebugLog: ((String) -> Void)?

    private var model: MLModel?
    private let ciContext = CIContext()
    private let inputWidth = 518
    private let inputHeight = 392
    
    // 1. Your brilliant Semaphore Lock to prevent memory crashes!
    private var isRunning = false

    private init() {
        // 2. Your brilliant background loader so the app opens instantly!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadModel()
        }
    }

    private func loadModel() {
        guard let modelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            onDebugLog?("❌ Depth model not found in bundle")
            return
        }
        do {
            // Bypasses the Neural Engine freeze
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU
            model = try MLModel(contentsOf: modelURL, configuration: config)
            onDebugLog?("✅ Depth model loaded")
        } catch {
            onDebugLog?("❌ Depth model failed to load: \(error)")
        }
    }

    func runSmokeTest(on sourcePixelBuffer: CVPixelBuffer) {
        // 3. The lock in action: If the GPU is busy, silently drop the frame and wait for the next one.
        guard !isRunning else { return }
        isRunning = true
        
        // Ensure the lock is ALWAYS released when this function finishes, even if it crashes
        defer { isRunning = false }

        guard let model = model else {
            // Silently return instead of spamming "not loaded" while the background thread is still loading
            return
        }

        // .right correctly orients the raw landscape ARKit buffer for the neural engine
        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer).oriented(.right)
        guard let inputBuffer = resizedPixelBuffer(from: sourceImage, width: inputWidth, height: inputHeight) else {
            onDebugLog?("❌ Failed to build input buffer")
            return
        }

        do {
            let inputValue = MLFeatureValue(pixelBuffer: inputBuffer)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputValue])

            let start = CFAbsoluteTimeGetCurrent()
            let output = try model.prediction(from: provider)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

            guard let depthBuffer = output.featureValue(for: "depth")?.imageBufferValue else {
                onDebugLog?("❌ No depth output found")
                return
            }

            CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
            let w = CVPixelBufferGetWidth(depthBuffer)
            let h = CVPixelBufferGetHeight(depthBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(depthBuffer)
            
            if let base = CVPixelBufferGetBaseAddress(depthBuffer) {
                let centerRow = h / 2
                let centerCol = w / 2
                let elementsPerRow = rowBytes / MemoryLayout<Float16>.stride  // accounts for any row padding
                let ptr = base.assumingMemoryBound(to: Float16.self)
                let centerValue = ptr[centerRow * elementsPerRow + centerCol]
                
                // We print the raw AI value to prove the plumbing works!
                onDebugLog?("✅ Depth ran in \(String(format: "%.1f", elapsedMs))ms — center value: \(Float(centerValue))")
            } else {
                // If iOS blocks memory access, this will tell us!
                onDebugLog?("❌ Could not read pixel buffer memory!")
            }
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)

        } catch {
            onDebugLog?("❌ Depth prediction failed: \(error)")
        }
    }

    private func resizedPixelBuffer(from ciImage: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                             kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        let scaleX = CGFloat(width) / ciImage.extent.width
        let scaleY = CGFloat(height) / ciImage.extent.height
        ciContext.render(ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)), to: buffer)
        return buffer
    }
}