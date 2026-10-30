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
  let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
  precondition(tracks.count == 1)
  print("PASS: timed-out waiter allows delayed writer completion and playable media")
 }

 static func probeStalledAudioDrain() async throws {
  let url = URL(fileURLWithPath: CommandLine.arguments[1] + ".stalled.mp4")
  let recorder = ScreenVideoRecorder(url: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = StalledAudioInput(mediaType: .audio, outputSettings: audioOutputSettings)
  writer.add(input)
  precondition(writer.startWriting())
  let start = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(seconds: 1, preferredTimescale: 16000)
  writer.startSession(atSourceTime: start)
  while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
  let sample = try audioBuffer([Int16](repeating: 100, count: 1600), time: start)
  precondition(input.append(sample))
  recorder.writer = writer; recorder.audioInput = input
  recorder.firstTime = start; recorder.audioSamples = 1600
  input.blocked.withLock { $0 = true }
  let finalized = OSAllocatedUnfairLock(initialState: 0)
  recorder.onFinalized = { finalized.withLock { $0 += 1 } }
  let began = ContinuousClock.now
  _ = try await recorder.stop(timeout: 5)
  precondition(ContinuousClock.now - began < .seconds(5))
  precondition(finalized.withLock { $0 } == 1)
  precondition(recorder.audioSamples == 1600)
  precondition(writer.status == .completed)
  let asset = AVURLAsset(url: url)
  let tracks = try await asset.loadTracks(withMediaType: .audio)
  let duration = try await asset.load(.duration)
  precondition(tracks.count == 1 && CMTimeGetSeconds(duration) > 0)
  print("PASS: permanently stalled audio input finalizes existing media within the drain deadline")
 }

}
@main struct Probe { static func main() async throws { try await ScreenVideoRecorder.probe(); try await ScreenVideoRecorder.probeDelayedFinalization(); try await ScreenVideoRecorder.probeStalledAudioDrain() } }
"""

with tempfile.TemporaryDirectory(prefix="muesli-meeting-encoding-") as directory:
    folder = Path(directory)
    source = folder / "Probe.swift"
    source.write_text(SOURCE.read_text().replace("import MuesliCore", "") + (ROOT / "native/MuesliNative/Sources/MuesliCore/MeetingVideoAudio.swift").read_text() + HARNESS)
    executable = folder / "probe"
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(folder / "audio.mp4")], check=True, timeout=30)
