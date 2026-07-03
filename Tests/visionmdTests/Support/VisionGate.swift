import CoreGraphics
import Foundation
import Vision

// MARK: - Vision capability gate
//
// CI VMs occasionally lack on-device Vision model assets. Probe once with a
// tiny request; gate Vision-dependent tests with
// `@Test(.enabled(if: VisionGate.available))` so the suite degrades to
// "skipped" instead of failing. Kill switch: VISIONMD_SKIP_VISION=1.

enum VisionGate {

    static let available: Bool = {
        if ProcessInfo.processInfo.environment["VISIONMD_SKIP_VISION"] == "1" {
            return false
        }
        // Tiny white image with a black line of "text"-ish pixels — enough to
        // exercise model loading without caring about the result.
        guard let ctx = CGContext(
            data: nil, width: 64, height: 32,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 12, width: 48, height: 8))
        guard let image = ctx.makeImage() else { return false }

        // Synchronously probe from a detached async context.
        final class ResultBox: @unchecked Sendable {
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
        }
        let box = ResultBox()
        Task.detached {
            do {
                let request = RecognizeDocumentsRequest()
                _ = try await request.perform(on: image)
                box.ok = true
            } catch {
                box.ok = false
            }
            box.semaphore.signal()
        }
        box.semaphore.wait()
        return box.ok
    }()
}
