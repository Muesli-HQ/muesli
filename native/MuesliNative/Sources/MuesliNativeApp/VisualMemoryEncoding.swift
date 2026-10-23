import AppKit
import AVFoundation
import ImageIO
import Vision
import VideoToolbox

enum VisualMemoryEncoding {
    struct Snapshot: @unchecked Sendable { let image: CGImage }
    struct Encoded: Sendable { let data: Data; let text: String; let fingerprint: Data }
    static func encode(_ snapshot: Snapshot) throws -> Encoded {
        // Detach ScreenCaptureKit's IOSurface-backed image before asynchronous OCR
        // and ImageIO encoding, using an explicit full-size RGB bitmap.
        let original = snapshot.image
        guard let bitmap = CGContext(data: nil, width: original.width, height: original.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScreenVideoRecorder.error("Cannot allocate screenshot bitmap.")
        }
        bitmap.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        guard let image = bitmap.makeImage() else { throw ScreenVideoRecorder.error("Cannot normalize screenshot.") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            throw ScreenVideoRecorder.error("HEIC encoding is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenVideoRecorder.error("Cannot save screen image.") }
        guard let encodedSource = CGImageSourceCreateWithData(data, nil),
              let decoded = CGImageSourceCreateImageAtIndex(encodedSource, 0, nil),
              decoded.width == image.width, decoded.height == image.height else {
            throw ScreenVideoRecorder.error("Encoded screenshot failed validation; no image was saved.")
        }
        // Exact small-image fingerprint is only a hint; text equality is checked too.
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return Encoded(data: data as Data, text: text, fingerprint: Data(bytes: context.data!, count: 64 * 256))
    }

    /// Packed archive time is one second per frame. Original timestamps remain in SQLite.
    static func compact(images: [URL], destination: URL) async throws {
        guard let first = images.first, let source = CGImageSourceCreateWithURL(first as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScreenVideoRecorder.error("Missing snapshot.") }
        guard ScreenVideoRecorder.hasHardwareEncoder(kCMVideoCodecType_HEVC) else { throw ScreenVideoRecorder.error("HEVC hardware unavailable.") }
        let width = image.width / 2 * 2, height = image.height / 2 * 2
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.6, AVVideoMaxKeyFrameIntervalKey: 25, AVVideoAllowFrameReorderingKey: false]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw ScreenVideoRecorder.error("Cannot prepare archive writer.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ScreenVideoRecorder.error("Archive start failed.") }
        writer.startSession(atSourceTime: .zero)
        do {
            for (index, url) in images.enumerated() {
                try Task.checkCancellation()
                let deadline = Date().addingTimeInterval(10)
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, Date() < deadline else { throw writer.error ?? ScreenVideoRecorder.error("Archive encoder stalled.") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let frame = CGImageSourceCreateImageAtIndex(source, 0, nil),
                          frame.width / 2 * 2 == width, frame.height / 2 * 2 == height,
                          let pool = adaptor.pixelBufferPool else { throw ScreenVideoRecorder.error("Snapshot dimensions changed.") }
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw ScreenVideoRecorder.error("Archive allocation failed.") }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw ScreenVideoRecorder.error("Archive rendering failed.") }
                    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 1)) else { throw writer.error ?? ScreenVideoRecorder.error("Archive write failed.") }
                }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(images.count), timescale: 1))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? ScreenVideoRecorder.error("Archive finalization failed.") }
        } catch { writer.cancelWriting(); try? FileManager.default.removeItem(at: destination); throw error }
    }
}
