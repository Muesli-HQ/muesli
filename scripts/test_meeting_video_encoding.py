#!/usr/bin/env python3
"""macOS regression: exercise production AAC settings and PCM sample construction.
Uses only synthetic audio; does not capture the screen or microphone.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "native/MuesliNative/Sources/MuesliNativeApp/ScreenVideoRecorder.swift"
HARNESS = r"""
final class StalledAudioInput: AVAssetWriterInput, @unchecked Sendable {
 let blocked = OSAllocatedUnfairLock(initialState: false)
 override var isReadyForMoreMediaData: Bool {
  !blocked.withLock { $0 } && super.isReadyForMoreMediaData
 }
}
extension ScreenVideoRecorder {
 static func probe() async throws {
  let url = URL(fileURLWithPath: CommandLine.arguments[1])
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
  writer.add(input)
  precondition(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  for i in 0..<20 {
   while !input.isReadyForMoreMediaData && writer.status == .writing { try await Task.sleep(for: .milliseconds(5)) }
   let sample = try audioBuffer([Int16](repeating: 100, count: 1600), time: CMTime(value:Int64(i*1600),timescale:16000))
   if !input.append(sample) { throw writer.error ?? error("Audio append failed") }
  }
  if writer.status == .writing { input.markAsFinished(); await writer.finishWriting() }
  guard writer.status == .completed else { throw writer.error ?? error("Writer did not finish") }
  let asset = AVURLAsset(url: url)
  let tracks = try await asset.loadTracks(withMediaType: .audio)
  let duration = try await asset.load(.duration)
  precondition(tracks.count == 1 && CMTimeGetSeconds(duration) >= 1.9)
  print("PASS: production meeting AAC settings encode a two-second audio track")
 }
 static func probeDelayedFinalization() async throws {
  let url = URL(fileURLWithPath: CommandLine.arguments[1] + ".delayed.mp4")
  let recorder = ScreenVideoRecorder(url: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
  writer.add(input)
  precondition(writer.startWriting())
  let start = CMClockGetTime(CMClockGetHostTimeClock())
  writer.startSession(atSourceTime: start)
  while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
  let sample = try audioBuffer([Int16](repeating: 100, count: 1600), time: start)
  precondition(input.append(sample))
  recorder.writer = writer; recorder.audioInput = input
  recorder.firstTime = start; recorder.audioSamples = 1600
  let resultCount = OSAllocatedUnfairLock(initialState: 0)
  recorder.onFinalizationResult = { result in
   if case .success = result { resultCount.withLock { $0 += 1 } }
  }
  let finalized = OSAllocatedUnfairLock(initialState: false)
  recorder.onFinalized = { finalized.withLock { $0 = true } }
  recorder.queue.suspend()
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { recorder.queue.resume() }
  do { _ = try await recorder.stop(timeout: 0.01); preconditionFailure("Expected waiter timeout") }
  catch { precondition(!finalized.withLock { $0 }) }
  for _ in 0..<200 {
   if finalized.withLock({ $0 }) { break }
   try await Task.sleep(for: .milliseconds(10))
  }
  precondition(finalized.withLock { $0 })
  precondition(writer.status == .completed)
  precondition(resultCount.withLock { $0 } == 1)
  let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
  precondition(tracks.count == 1)
  print("PASS: timed-out waiter allows delayed writer completion and playable media")
 }

 static func probeStalledAudioDrain() async throws {
  for (feedback, recordedError) in [(false, false), (true, false), (true, true)] {
  let url = URL(fileURLWithPath: CommandLine.arguments[1] + (recordedError ? ".drain-error.mp4" : feedback ? ".partial-feedback.mp4" : ".stalled.mp4"))
  let recorder = ScreenVideoRecorder(url: url, feedbackCapture: feedback)
  let wav = url.appendingPathExtension("wav")
  let narration = try MeetingRecordingWriter(destination: wav)
  try narration.appendMicrophone([Int16](repeating: 100, count: 16000), startFrame: 0)
  let finishedWAV = try narration.finishMicrophone(); precondition(finishedWAV == wav)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = StalledAudioInput(mediaType: .audio, outputSettings: audioOutputSettings)
  writer.add(input)
  precondition(writer.startWriting())
  let start = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(seconds: recordedError ? 12 : 1, preferredTimescale: 16000)
  writer.startSession(atSourceTime: start)
  while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
  let sample = try audioBuffer([Int16](repeating: 100, count: 1600), time: start)
  precondition(input.append(sample))
  recorder.writer = writer; recorder.audioInput = input
  recorder.firstTime = start; recorder.audioSamples = 1600
  input.blocked.withLock { $0 = true }
  let finalized = OSAllocatedUnfairLock(initialState: 0)
  let result = OSAllocatedUnfairLock<(count: Int, message: String?)>(initialState: (0, nil))
  recorder.onFinalized = { finalized.withLock { $0 += 1 } }
  recorder.onFinalizationResult = { outcome in
   result.withLock { value in
    value.count += 1
    if case .failure(let failure) = outcome { value.message = failure.localizedDescription }
   }
  }
  let liveErrors = OSAllocatedUnfairLock(initialState: 0)
  if recordedError {
   let origin = Int64((CMTimeGetSeconds(start) * 16000).rounded())
   recorder.audio.withLock { $0 = MeetingVideoAudioBuffer(start: origin + 1600) }
   recorder.requestStop(at: start + CMTime(seconds: 12, preferredTimescale: 16000))
   recorder.onFailure = { _ in
    precondition(recorder.isStopping, "The failure must arrive after Finish begins draining")
    liveErrors.withLock { $0 += 1 }
   }
   recorder.queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
    recorder.appendAudio([Int16](repeating: 1, count: 160_001), microphone: true, startFrame: origin + 1600)
   }
  }
  let began = ContinuousClock.now
  var reportedError: String?
  do { _ = try await recorder.stop(timeout: 5) }
  catch { reportedError = error.localizedDescription }
  precondition(ContinuousClock.now - began < .seconds(5))
  precondition(finalized.withLock { $0 } == 1)
  precondition(recorder.audioSamples == 1600)
  precondition(writer.status == .completed)
  let asset = AVURLAsset(url: url)
  let tracks = try await asset.loadTracks(withMediaType: .audio)
  let duration = try await asset.load(.duration)
  precondition(tracks.count == 1 && CMTimeGetSeconds(duration) > 0)
  let fullNarration = try Data(contentsOf: wav)
  precondition(fullNarration.count == 32044)
  precondition(result.withLock { $0.count } == 1)
  if recordedError {
   guard liveErrors.withLock({ $0 }) == 1,
         reportedError == "Audio encoding fell behind.",
         result.withLock({ $0.message }) == reportedError else {
    throw error("Playable writer completion lost the error recorded during final audio drain: waiter=\(reportedError ?? "success"), callback=\(result.withLock { $0.message } ?? "success")")
   }
   print("Recorded drain error survives actual finalization callback with playable media and complete WAV")
  } else {
   precondition((reportedError != nil) == feedback, "Feedback AAC drain timeout must report partial narration instead of success")
  print(feedback ? "PASS: stalled feedback AAC reports partial narration while preserving playable MP4 and complete WAV" : "PASS: permanently stalled audio input finalizes existing media within the drain deadline")
  }
  }
 }

 static func probeFeedbackFragments() async throws {
  let url = URL(fileURLWithPath: CommandLine.arguments[1] + ".feedback.mp4")
  let recorder = ScreenVideoRecorder(url: url, feedbackCapture: true)
  try recorder.prepareWriter(width: 64, height: 64)
  let writer = recorder.writer!
  precondition(CMTimeGetSeconds(writer.movieFragmentInterval) == 2)
  let codec = recorder.videoInput!.outputSettings![AVVideoCodecKey] as! AVVideoCodecType
  precondition(codec == (hasHardwareEncoder(kCMVideoCodecType_HEVC) ? .hevc : .h264))
  precondition(recorder.audioInput!.outputSettings![AVFormatIDKey] as! UInt32 == kAudioFormatMPEG4AAC)
  var pixel: CVPixelBuffer?
  precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
  let frame = pixel!
  CVPixelBufferLockBaseAddress(frame, [])
  memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
  CVPixelBufferUnlockBaseAddress(frame, [])
  var format: CMVideoFormatDescription?
  precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format) == noErr)
  // An initial burst followed by static-screen updates at two-second intervals.
  let times = (0...30).map { Double($0) / 15 } + [4, 6, 8]
  let origin = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(seconds: 9, preferredTimescale: 16000)
  for seconds in times {
   var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
    presentationTimeStamp: origin + CMTime(seconds: seconds, preferredTimescale: 16000), decodeTimeStamp: .invalid)
   var sample: CMSampleBuffer?
   precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame,
    formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
   _ = await recorder.testing_appendVideoFrame(sample!)
   if seconds == 0 {
    let start = recorder.firstTime!
    recorder.appendAudio((0..<128000).map { Int16(sin(Double($0) * 0.17) * 4000) }, microphone: true,
     startFrame: Int64((CMTimeGetSeconds(start) * 16000).rounded()))
   }
   try await Task.sleep(for: .milliseconds(10))
  }
  try await Task.sleep(for: .milliseconds(500))
  precondition(recorder.failure == nil && recorder.audioSamples == 128000)
  let interrupted = URL(fileURLWithPath: url.path + ".interrupted.mp4")
  try FileManager.default.copyItem(at: url, to: interrupted)
  recorder.queue.sync { recorder.audioTimer?.cancel(); recorder.audioTimer = nil; writer.cancelWriting() }
  let asset = AVURLAsset(url: interrupted)
  let duration = try await asset.load(.duration)
  let tracks = try await asset.loadTracks(withMediaType: .video)
  let audio = try await asset.loadTracks(withMediaType: .audio)
  let playable = try await asset.load(.isPlayable)
  precondition(playable && tracks.count == 1 && audio.count == 1 && CMTimeGetSeconds(duration) >= 2)
  let videoDuration = CMTimeGetSeconds(try await tracks[0].load(.timeRange).duration)
  print("Interrupted production \(codec.rawValue)+AAC: asset=\(CMTimeGetSeconds(duration))s video=\(videoDuration)s")
  guard videoDuration >= 6 else { throw error("Sparse production fragments lost more than the final two seconds: video=\(videoDuration)s after 8s") }
  let generator = AVAssetImageGenerator(asset: asset)
  let decoded = try await generator.image(at: CMTime(seconds: 4, preferredTimescale: 600))
  precondition(decoded.image.width == 64 && decoded.image.height == 64)
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
   AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32])
  reader.add(output); precondition(reader.startReading())
  var count = 0, peak: Float = 0
  while let sample = output.copyNextSampleBuffer() {
   let block = CMSampleBufferGetDataBuffer(sample)!
   var length = 0; var pointer: UnsafeMutablePointer<Int8>?
   precondition(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
    totalLengthOut: &length, dataPointerOut: &pointer) == noErr)
   pointer!.withMemoryRebound(to: Float.self, capacity: length / 4) { data in
    for value in UnsafeBufferPointer(start: data, count: length / 4) { peak = max(peak, abs(value)) }
   }
   count += CMSampleBufferGetNumSamples(sample)
  }
  precondition(reader.status == .completed && count >= 32000 && peak > 0.01)
  print("PASS: interrupted production audiovisual fragments retain sparse video, decode native frame and AAC narration")
 }

 static func probeFirstAcceptedVideoFrame() async throws {
  let url = URL(fileURLWithPath: CommandLine.arguments[1] + ".first-frame.mp4")
  let recorder = ScreenVideoRecorder(url: url, feedbackCapture: true)
  let writer = try recorder.makeWriter()
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
   AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
  let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
  writer.add(input); writer.add(sound)
  recorder.writer = writer; recorder.videoInput = input; recorder.audioInput = sound
  var pixel: CVPixelBuffer?
  precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
  var format: CMVideoFormatDescription?
  precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
  let frame = OSAllocatedUnfairLock<Int64?>(initialState: nil)
  recorder.onFirstVideoFrame = { value in frame.withLock { $0 = value } }
  for i in 0..<30 {
   var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
    presentationTimeStamp: CMTime(value: Int64(150 + i), timescale: 15), decodeTimeStamp: .invalid)
   var sample: CMSampleBuffer?
   precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!,
    formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
   recorder.appendVideoFrame(sample!)
   if let accepted = frame.withLock({ $0 }) {
    precondition(accepted == Int64((CMTimeGetSeconds(timing.presentationTimeStamp) * 16000).rounded()))
    precondition(recorder.firstTime == timing.presentationTimeStamp)
    break
   }
   try await Task.sleep(for: .milliseconds(5))
  }
  precondition(frame.withLock { $0 } != nil)
  let first = recorder.firstTime!
  let cutoff = first + CMTime(value: 3200, timescale: 16000)
  recorder.requestStop(at: cutoff)
  let acceptedLast = recorder.lastTime
  var lateTiming = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
   presentationTimeStamp: cutoff + CMTime(seconds: 1, preferredTimescale: 16000), decodeTimeStamp: .invalid)
  var late: CMSampleBuffer?
  precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!,
   formatDescription: format!, sampleTiming: &lateTiming, sampleBufferOut: &late) == noErr)
  recorder.appendVideoFrame(late!)
  precondition(recorder.lastTime == acceptedLast) // Finish rejects frames before writer closure.
  try await Task.sleep(for: .milliseconds(100)) // A slow microphone producer is still draining.
  recorder.appendAudio([Int16](repeating: 1234, count: 3200), microphone: true,
   startFrame: Int64((CMTimeGetSeconds(first) * 16000).rounded()))
  let duration = try await recorder.stop()
  precondition(abs(duration - 0.2) < 0.001)
  precondition(recorder.audioSamples == 3200 && writer.status == .completed)
  let asset = AVURLAsset(url: url)
  let saved = try await asset.load(.duration)
  precondition(CMTimeGetSeconds(saved) < 0.3)
  print("PASS: first-frame anchor and Finish cutoff reject later video, drain delayed PCM and bound saved duration")
 }
 static func probeDelayedFeedbackNarration() async throws {
  var failures: [String] = []
  for (blockSize, deliveryFrames) in [(512, 1280), (4096, 1280), (512, 12800), (4096, 12800), (32768, 0)] {
   let url = URL(fileURLWithPath: CommandLine.arguments[1] + ".delivered-\(blockSize)-\(deliveryFrames).mp4")
   let wavURL = URL(fileURLWithPath: url.path + ".wav")
   let narration = try MeetingRecordingWriter(destination: wavURL)
   let recorder = ScreenVideoRecorder(url: url, feedbackCapture: true)
   let start = CMTime(seconds: 1000, preferredTimescale: 16000)
   let origin: Int64 = 16_000_000
   let samples = (0..<32768).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16000) * 12000) }
   let writer: AVAssetWriter
   let input: AVAssetWriterInput
   var offset = 0
   if deliveryFrames == 0 {
    try recorder.prepareWriter(width: 64, height: 64)
    writer = recorder.writer!; input = recorder.audioInput!
    // Mic delivery can beat the first screen callback; keep only the overlapping PCM.
    recorder.appendAudio([Int16](repeating: 999, count: 100) + samples, microphone: true, startFrame: origin - 100)
    try narration.appendMicrophone(samples, startFrame: origin)
    offset = samples.count
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    var format: CMVideoFormatDescription?
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: start, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!,
     formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    while !(await recorder.testing_appendVideoFrame(sample!)) { try await Task.sleep(for: .milliseconds(5)) }
    recorder.queue.sync { recorder.audioTimer?.cancel(); recorder.audioTimer = nil }
   } else {
    writer = try recorder.makeWriter()
    input = StalledAudioInput(mediaType: .audio, outputSettings: audioOutputSettings)
    writer.add(input); precondition(writer.startWriting())
    writer.startSession(atSourceTime: start)
    recorder.writer = writer; recorder.audioInput = input; recorder.firstTime = start
    recorder.audio.withLock { $0 = MeetingVideoAudioBuffer(start: origin) }
   }
   let delivery = DispatchQueue(label: "feedback-delivery-fixture")
   // Completed hardware blocks arrive 80 or 800 ms after capture. A loaded
   // processing queue must not let the writer consume their positions early.
   for tick in 1...20 {
    let captured = tick * 1600
    while offset + blockSize + deliveryFrames <= captured {
     let position = offset, block = Array(samples[offset..<(offset + blockSize)])
     delivery.async {
      try! narration.appendMicrophone(block, startFrame: origin + Int64(position))
      recorder.appendAudio(block, microphone: true, startFrame: origin + Int64(position))
     }
     offset += blockSize
    }
    delivery.sync {}
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
    recorder.writeAudio(at: start + CMTime(value: Int64(captured), timescale: 16000))
   }
   // Stop drains every already-captured block, including a non-100-ms tail.
   while offset < samples.count {
    let end = min(samples.count, offset + blockSize)
    let position = offset, block = Array(samples[offset..<end])
    delivery.async {
     try! narration.appendMicrophone(block, startFrame: origin + Int64(position))
     recorder.appendAudio(block, microphone: true, startFrame: origin + Int64(position))
    }
    offset = end
   }
   delivery.sync {}
   _ = try narration.finishMicrophone()
   let fullChunks = Int64(samples.count / 1600 * 1600)
   while recorder.audioSamples < fullChunks && writer.status == .writing {
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
    recorder.writeAudio(flush: true, targetOverride: fullChunks)
   }
   // Even the final sub-100-ms chunk must wait for temporary encoder backpressure.
   if let stalled = input as? StalledAudioInput {
    stalled.blocked.withLock { $0 = true }
    delivery.asyncAfter(deadline: .now() + .milliseconds(50)) { stalled.blocked.withLock { $0 = false } }
   }
   let result: Result<Double, Error> = await withCheckedContinuation { continuation in
    recorder.drainAndFinish(target: Int64(samples.count), start: start, deadline: .now() + .seconds(2)) {
     continuation.resume(returning: $0)
    }
   }
   _ = try result.get()
   guard writer.status == .completed else { throw writer.error ?? error("Delivery fixture did not finalize") }
   let asset = AVURLAsset(url: url)
   let tracks = try await asset.loadTracks(withMediaType: .audio)
   let reader = try AVAssetReader(asset: asset)
   let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
   reader.add(output); precondition(reader.startReading())
   var decoded: [Float] = []
   while let buffer = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(buffer) {
    var block = [Float](repeating: 0, count: CMSampleBufferGetNumSamples(buffer))
    let status = block.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0,
     dataLength: $0.count, destination: $0.baseAddress!) }
    precondition(status == noErr); decoded += block
   }
   guard reader.status == .completed else { throw reader.error ?? error("Cannot decode narration fixture") }
   let wav = try Data(contentsOf: wavURL).dropFirst(44)
   let expected = stride(from: wav.startIndex, to: wav.endIndex, by: 2).map {
    Float(Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)) / 32768
   }
   let compared = min(decoded.count, expected.count)
   let mse = zip(decoded.prefix(compared), expected.prefix(compared)).reduce(0.0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) } / Double(compared)
   if wav.count != samples.count * 2 || recorder.audioSamples != samples.count || decoded.count < samples.count || mse > 0.001 {
    failures.append("\(blockSize)-sample delivery delayed \(deliveryFrames / 16) ms: WAV=\(wav.count / 2), encoded=\(recorder.audioSamples), decoded=\(decoded.count), MSE=\(mse)")
   }
   print("Narration fixture \(blockSize)/\(deliveryFrames / 16)ms: WAV=\(wav.count / 2) encoded=\(recorder.audioSamples) decoded=\(decoded.count) MSE=\(mse)")
  }
  guard failures.isEmpty else { throw error("Delayed MP4 narration mismatch: " + failures.joined(separator: "; ")) }
  print("PASS: pre-video and asynchronous 512/4096-sample delivery and Finish tail match WAV narration in decoded MP4")
 }
 static func probeFeedbackAudioDelay() async throws {
  var failures: [String] = []
  for (feedback, mode) in [(false, "initial"), (true, "initial"), (false, "silence"),
   (true, "silence"), (true, "dropout"), (true, "resume"), (true, "late"), (true, "future"),
   (true, "capacity"), (true, "early-capacity"), (true, "flush")] {
   let url = URL(fileURLWithPath: CommandLine.arguments[1] + ".delay-\(feedback)-\(mode).mp4")
   let recorder = ScreenVideoRecorder(url: url, feedbackCapture: feedback)
   let writer = try recorder.makeWriter()
   let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
   writer.add(input); precondition(writer.startWriting())
   let start = CMTime(seconds: 1000, preferredTimescale: 16000), origin: Int64 = 16_000_000
   writer.startSession(atSourceTime: start)
   while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
   recorder.writer = writer; recorder.audioInput = input
   if mode != "early-capacity" {
    recorder.firstTime = start
    recorder.audio.withLock { $0 = MeetingVideoAudioBuffer(start: origin) }
   }
   if mode == "initial" {
    recorder.writeAudio(at: start + CMTime(seconds: 1, preferredTimescale: 16000))
    precondition(recorder.audioSamples == 0)
    recorder.appendAudio([Int16](repeating: 100, count: 16000), microphone: true, startFrame: origin)
    recorder.writeAudio(at: start + CMTime(seconds: 1, preferredTimescale: 16000))
    precondition(feedback ? recorder.audioSamples > 0 : recorder.audioSamples == 0)
   } else if mode == "future" {
    recorder.appendAudio([123, 456], microphone: true, startFrame: origin + 192000)
    let tail = recorder.audio.withLock { $0?.take(count: 192002).suffix(2) }
    if tail.map(Array.init) != [123, 456] { failures.append("resumed PCM lost its original future keys") }
   } else if mode == "capacity" || mode == "early-capacity" {
    let failed = OSAllocatedUnfairLock(initialState: 0)
    recorder.onFailure = { _ in failed.withLock { $0 += 1 } }
    recorder.appendAudio([Int16](repeating: 1, count: 160000), microphone: true, startFrame: origin + 192000)
    recorder.appendAudio([2, 3], microphone: true, startFrame: origin + 192000) // Replacements use no capacity.
    recorder.queue.sync {}
    if failed.withLock({ $0 }) != 0 { failures.append("overlap incorrectly exhausted capacity") }
    recorder.appendAudio([4, 5], microphone: true, startFrame: origin + 352000)
    recorder.queue.sync {} // The real overflow callback must run outside the audio lock.
    if failed.withLock({ $0 }) != 1 || recorder.audio.withLock({ $0 != nil }) {
     failures.append("\(mode): actual unique PCM overflow was not failed and closed")
    }
    recorder.appendAudio([6], microphone: true, startFrame: origin + 352002)
    if recorder.audio.withLock({ $0 != nil }) { failures.append("\(mode): late PCM reopened the failed buffer") }
   } else if mode == "flush" {
    recorder.requestStop(at: start + CMTime(seconds: 12, preferredTimescale: 16000))
    do { _ = try await recorder.stop() } catch { failures.append("feedback final flush failed: \(error.localizedDescription)") }
    if recorder.failure != nil || recorder.audioSamples != 192000 { failures.append("feedback final silence tripped elapsed lag guard") }
   } else {
    if mode == "dropout" || mode == "resume" {
     recorder.appendAudio([Int16](repeating: 100, count: 1600), microphone: true, startFrame: origin)
     recorder.writeAudio(at: start + CMTime(value: 1600, timescale: 16000))
    }
    recorder.writeAudio(at: start + CMTime(seconds: feedback ? 12 : 15, preferredTimescale: 16000))
    if (recorder.failure == nil) != feedback { failures.append("\(mode): silence over ten seconds changed capture failure incorrectly") }
    if feedback {
     let expected: Int64 = mode == "dropout" || mode == "resume" ? 1600 : 0
     if recorder.audioSamples != expected { failures.append("\(mode): live writer consumed undelivered positions") }
     if mode == "resume" || mode == "late" {
      let position = mode == "resume" ? origin + 192000 : origin
      recorder.appendAudio([123, 456], microphone: true, startFrame: position)
      let retained = recorder.audio.withLock { $0?.take(count: Int(position - origin - expected) + 2).suffix(2) }
      if retained.map(Array.init) != [123, 456] { failures.append("\(mode): delayed PCM was discarded or retimed") }
     }
    }
   }
   if writer.status == .writing { writer.cancelWriting() }
  }
  guard failures.isEmpty else { throw error("Feedback delivery regression: " + failures.joined(separator: "; ")) }
  print("PASS: feedback silence/dropout, original resumed/late PCM, actual capacity and final flush; meeting AEC/lag unchanged")
 }

}
@main struct Probe { static func main() async throws { try await ScreenVideoRecorder.probe(); try await ScreenVideoRecorder.probeDelayedFinalization(); try await ScreenVideoRecorder.probeStalledAudioDrain(); try await ScreenVideoRecorder.probeFeedbackFragments(); try await ScreenVideoRecorder.probeFeedbackAudioDelay(); try await ScreenVideoRecorder.probeFirstAcceptedVideoFrame(); try await ScreenVideoRecorder.probeDelayedFeedbackNarration() } }
"""

with tempfile.TemporaryDirectory(prefix="muesli-meeting-encoding-") as directory:
    folder = Path(directory)
    source = folder / "Probe.swift"
    source.write_text(SOURCE.read_text().replace("import MuesliCore", "") + (ROOT / "native/MuesliNative/Sources/MuesliCore/MeetingVideoAudio.swift").read_text() + (ROOT / "native/MuesliNative/Sources/MuesliNativeApp/WavWriter.swift").read_text() + (ROOT / "native/MuesliNative/Sources/MuesliNativeApp/FeedbackCaptureAudioWriting.swift").read_text() + (ROOT / "native/MuesliNative/Sources/MuesliNativeApp/MeetingRecordingWriter.swift").read_text() + HARNESS)
    executable = folder / "probe"
    subprocess.run(["swiftc", "-j4", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(folder / "audio.mp4")], check=True, timeout=30)
