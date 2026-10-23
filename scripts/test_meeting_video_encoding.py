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
}
@main struct Probe { static func main() async throws { try await ScreenVideoRecorder.probe() } }
"""

with tempfile.TemporaryDirectory(prefix="muesli-meeting-encoding-") as directory:
    folder = Path(directory)
    source = folder / "Probe.swift"
    source.write_text(SOURCE.read_text() + HARNESS)
    executable = folder / "probe"
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(folder / "audio.mp4")], check=True, timeout=30)
