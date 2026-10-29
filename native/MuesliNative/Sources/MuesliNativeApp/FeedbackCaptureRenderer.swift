import AppKit
import AVFoundation
import CoreText
import MuesliCore

/// Native cancellation is registered before decoding, including when expiry won the race.
final class FeedbackCaptureDecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var stop: (() -> Void)?
    func install(_ stop: @escaping () -> Void) throws {
        let retired = lock.withLock { () -> Bool in
            if cancelled { return true }; self.stop = stop; return false
        }
        if retired { stop(); throw CancellationError() }
    }
    func cancel() {
        let stop = lock.withLock { cancelled = true; return self.stop }
        stop?()
    }
    func check() throws {
        try Task.checkCancellation()
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// Returning on expiry never waits for a noncooperative native decoder. Its result
/// is retired, and only the successful caller may subsequently write artifacts.
actor FeedbackCaptureMediaJob<Value: Sendable> {
    private var result: CheckedContinuation<Value, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cancelNative: (@Sendable () -> Void)?
    private var used = false
    func run(timeout: Duration, cancel: @escaping @Sendable () -> Void,
             operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !used else { throw ScreenVideoRecorder.error("Media job already used") }
        used = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result = continuation; cancelNative = cancel
                worker = Task.detached(priority: .utility) {
                    do {
                        let value = try await operation()
                        try Task.checkCancellation()
                        await self.complete(.success(value))
                    } catch { await self.complete(.failure(error)) }
                }
                timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    expire(ScreenVideoRecorder.error("Media stage timed out"))
                }
            }
        } onCancel: { Task { await self.expire(CancellationError()) } }
    }
    private func expire(_ error: Error) {
        guard result != nil else { return }
        cancelNative?(); worker?.cancel()
        complete(.failure(error))
    }
    private func complete(_ value: Result<Value, Error>) {
        guard let result else { return }
        self.result = nil; timer?.cancel(); timer = nil; worker = nil; cancelNative = nil
        result.resume(with: value)
    }
}

/// Each kind has its own permit. Expired native work retains its permit until it
/// actually returns; a subsequent capture cannot multiply still-running decoders.
actor FeedbackCaptureMediaLimiter {
    static let thumbnails = FeedbackCaptureMediaLimiter()
    static let render = FeedbackCaptureMediaLimiter()
    private var busy = false
    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        while busy { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        busy = true; defer { busy = false }
        return try await operation()
    }
}

enum FeedbackCaptureRenderer {
    struct Frame: Sendable { var keyframe: FeedbackCaptureKeyframe; let png: Data }
    struct Output: Sendable { var frames: [Frame]; var contactSheet: Data?; var failures: [FeedbackCaptureFailure] }

    static func thumbnails(url: URL, videoOffsetMs: Int64, cancellation: FeedbackCaptureDecodeCancellation) async throws -> [FeedbackCaptureContext.Thumbnail] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScreenVideoRecorder.error("Video track unavailable") }
        try cancellation.check()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ScreenVideoRecorder.error("Cannot read video thumbnails") }
        reader.add(output)
        try cancellation.install { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? ScreenVideoRecorder.error("Cannot start video reader") }
        defer { reader.cancelReading() }
        var thumbnails: [FeedbackCaptureContext.Thumbnail] = []
        var pendingFinalSample: CMSampleBuffer?
        var next = 0.0
        func makeThumbnail(_ sample: CMSampleBuffer) throws -> FeedbackCaptureContext.Thumbnail? {
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard seconds.isFinite, let pixel = CMSampleBufferGetImageBuffer(sample) else { return nil }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw ScreenVideoRecorder.error("Video pixels unavailable") }
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), stride = CVPixelBufferGetBytesPerRow(pixel)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var luma = [UInt8](); luma.reserveCapacity(64 * 36)
            for y in 0..<36 {
                for x in 0..<64 {
                    let p = min(height - 1, y * height / 36) * stride + min(width - 1, x * width / 64) * 4
                    var weightedLuma = 77 * Int(bytes[p + 2])
                    weightedLuma += 150 * Int(bytes[p + 1])
                    weightedLuma += 29 * Int(bytes[p])
                    luma.append(UInt8(weightedLuma / 256))
                }
            }
            return .init(t: Int64((seconds * 1000).rounded()) + videoOffsetMs, luma: luma)
        }
        while reader.status == .reading {
            try cancellation.check()
            let hasSample = try autoreleasepool { () throws -> Bool in
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard seconds.isFinite, CMSampleBufferGetImageBuffer(sample) != nil else { return true }
                guard seconds + 0.0001 >= next else {
                    pendingFinalSample = sample
                    return true
                }
                guard let thumbnail = try makeThumbnail(sample) else { return true }
                thumbnails.append(thumbnail)
                pendingFinalSample = nil
                next = (floor(seconds * 4 + 0.0001) + 1) / 4
                return true
            }
            if !hasSample { break }
        }
        try cancellation.check()
        if reader.status == .failed { throw reader.error ?? ScreenVideoRecorder.error("Video thumbnail decoding failed") }
        if let pendingFinalSample {
            try cancellation.check()
            let finalThumbnail = try autoreleasepool { () throws -> FeedbackCaptureContext.Thumbnail? in
                try makeThumbnail(pendingFinalSample)
            }
            if let finalThumbnail, finalThumbnail.t > (thumbnails.last?.t ?? Int64.min) {
                thumbnails.append(finalThumbnail)
            }
        }
        guard !thumbnails.isEmpty else { throw ScreenVideoRecorder.error("No video thumbnails decoded") }
        return thumbnails
    }

    static func render(_ manifest: FeedbackCaptureManifest, url: URL, cancellation: FeedbackCaptureDecodeCancellation) async throws -> Output {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScreenVideoRecorder.error("Video track unavailable") }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        guard size.width > 0, size.height > 0 else { throw ScreenVideoRecorder.error("Video dimensions unavailable") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let scale = min(1, 2560 / size.width)
        generator.maximumSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        try cancellation.install { generator.cancelAllCGImageGeneration() }
        defer { generator.cancelAllCGImageGeneration() }
        var result = Output(frames: [], contactSheet: nil, failures: [])
        var images: [CGImage] = []
        for selected in manifest.keyframes {
            try cancellation.check()
            do {
                let requested = CMTime(value: max(0, selected.t - (manifest.videoOffsetMs ?? 0)), timescale: 1000)
                let decoded = try await generator.image(at: requested)
                try cancellation.check()
                var frame = selected
                frame.t = Int64((decoded.actualTime.seconds * 1000).rounded()) + (manifest.videoOffsetMs ?? 0)
                let event = selected.eventIndex.flatMap { manifest.events.indices.contains($0) ? manifest.events[$0] : nil }
                let click = event.flatMap { $0.kind == .click ? CGPoint(x: $0.x, y: $0.y) : nil }
                let markStrokes = manifest.marks.filter { $0.frame == selected.file || $0.id == selected.markId }
                    .flatMap(\.strokes).filter { manifest.strokes.indices.contains($0) }.map { manifest.strokes[$0] }
                let image = try annotate(decoded.image, index: frame.index, click: click, strokes: markStrokes)
                result.frames.append(.init(keyframe: frame, png: try png(image)))
                if images.count < 12 { images.append(image) }
            } catch {
                try cancellation.check()
                result.failures.append(.init(stage: "render", message: "Frame #\(selected.index): \(error.localizedDescription)"))
            }
        }
        try cancellation.check()
        if !images.isEmpty {
            do { result.contactSheet = try png(contactSheet(images)) }
            catch { result.failures.append(.init(stage: "render", message: "Contact sheet: \(error.localizedDescription)")) }
        }
        return result
    }
    private static func png(_ image: CGImage) throws -> Data {
        guard let data = InsightsShareRenderer.pngData(for: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else {
            throw ScreenVideoRecorder.error("PNG encoding failed")
        }
        return data
    }
    private static func canvas(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenVideoRecorder.error("Cannot allocate frame canvas")
        }
        return context
    }
    static func annotate(_ image: CGImage, index: Int, click: CGPoint?, strokes: [FeedbackCaptureStroke] = []) throws -> CGImage {
        let context = try canvas(width: image.width, height: image.height + 60)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let source = CGRect(x: 0, y: 0, width: width, height: height)
        // Keep the embedded cursor and all source content clear of the number chip.
        context.setFillColor(red: 28.0 / 255, green: 29.0 / 255, blue: 34.0 / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: height, width: width, height: 60))
        context.draw(image, in: source)
        if let click {
            context.saveGState(); context.clip(to: source)
            let centre = CGPoint(x: click.x * width, y: (1 - click.y) * height)
            let radius = 14 * max(1, width / 1280)
            let ring = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)); context.setLineWidth(0.75)
            context.strokeEllipse(in: ring.insetBy(dx: -1.5, dy: -1.5))
            context.setStrokeColor(CGColor(red: 0, green: 136.0 / 255, blue: 1, alpha: 0.75)); context.setLineWidth(2.5)
            context.strokeEllipse(in: ring)
            context.setFillColor(CGColor(red: 0, green: 136.0 / 255, blue: 1, alpha: 0.8))
            context.fillEllipse(in: CGRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4))
            context.restoreGState()
        }
        context.saveGState(); context.clip(to: source)
        for stroke in strokes { drawInk(stroke, in: context, width: width, height: height) }
        context.restoreGState()
        let chip = CGRect(x: 12, y: height + 12, width: 36, height: 36)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: chip, cornerWidth: 7, cornerHeight: 7, transform: nil)); context.fillPath()
        let text = NSAttributedString(string: "\(index)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: chip.midX - textWidth / 2, y: chip.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
        guard let result = context.makeImage() else { throw ScreenVideoRecorder.error("Frame annotation failed") }
        return result
    }

    /// Shared by the live point-space overlay and exported pixel-space annotations.
    static func drawInk(_ stroke: FeedbackCaptureStroke, in context: CGContext, width: CGFloat, height: CGFloat) {
        guard stroke.fw > 0, stroke.fh > 0, stroke.pts.count >= 3 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.scaleBy(x: width / stroke.fw, y: height / stroke.fh)
        // Device components preserve the specified #FF3B30 bytes on exported canvases.
        context.setStrokeColor(red: 1, green: 59.0 / 255, blue: 48.0 / 255, alpha: 1)
        context.setFillColor(red: 1, green: 59.0 / 255, blue: 48.0 / 255, alpha: 1)
        context.setLineWidth(3); context.setLineCap(.round); context.setLineJoin(.round)
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: Double(stroke.pts[i]) / 10000 * stroke.fw, y: (1 - Double(stroke.pts[i + 1]) / 10000) * stroke.fh)
        }
        if let pin = stroke.pin {
            let p = point(0)
            context.strokeEllipse(in: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30))
            context.fillEllipse(in: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
            let text = NSAttributedString(string: "\(pin)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: p.x - CTLineGetTypographicBounds(line, nil, nil, nil) / 2, y: p.y - 4)
            CTLineDraw(line, context)
        } else {
            context.move(to: point(0))
            for i in stride(from: 3, to: stroke.pts.count, by: 3) { context.addLine(to: point(i)) }
            context.strokePath()
        }
    }

    static func contactSheet(_ images: [CGImage]) throws -> CGImage {
        guard !images.isEmpty else { throw ScreenVideoRecorder.error("No frames for contact sheet") }
        let gutter = 6.0
        var best: (width: Double, height: Double, rows: [[CGImage]])?
        // Aspect-justify chronological rows. Solve width with fixed 6 px gutters
        // rather than scaling a finished sheet (which would also scale the gutters).
        for columns in 1...images.count {
            let rows = stride(from: 0, to: images.count, by: columns).map { Array(images[$0..<min(images.count, $0 + columns)]) }
            let ratios = rows.map { $0.reduce(0.0) { $0 + Double($1.width) / Double($1.height) } }
            let inverse = ratios.reduce(0.0) { $0 + 1 / $1 }
            let offsets = zip(rows, ratios).reduce(0.0) { $0 + gutter * Double($1.0.count + 1) / $1.1 }
            let width = floor(min(1600, (1600 + offsets - gutter * Double(rows.count + 1)) / inverse))
            let height = ceil(width * inverse - offsets + gutter * Double(rows.count + 1))
            guard width > gutter * Double(columns + 1), height <= 1600 else { continue }
            if best == nil || width * height > best!.width * best!.height { best = (width, height, rows) }
        }
        guard let layout = best else { throw ScreenVideoRecorder.error("Contact sheet layout failed") }
        let context = try canvas(width: Int(layout.width), height: Int(layout.height))
        // Components are in the canvas space; a generic-RGB CGColor would
        // convert these bytes and change the specified #1C1D22 background.
        context.setFillColor(red: 28.0 / 255, green: 29.0 / 255, blue: 34.0 / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        var top = gutter
        for row in layout.rows {
            let ratio = row.reduce(0.0) { $0 + Double($1.width) / Double($1.height) }
            let height = (layout.width - gutter * Double(row.count + 1)) / ratio
            var x = gutter
            for image in row {
                let width = height * Double(image.width) / Double(image.height)
                context.draw(image, in: CGRect(x: x, y: layout.height - top - height, width: width, height: height))
                x += width + gutter
            }
            top += height + gutter
        }
        guard let result = context.makeImage() else { throw ScreenVideoRecorder.error("Contact sheet composition failed") }
        return result
    }
}
