import AVFoundation
import CryptoKit
import SwiftUI

private struct RecordingWaveformData: Equatable {
    static let defaultBucketCount = 512
    private static let cacheMagic = Data("MWF1".utf8)
    private static let cacheVersion: UInt16 = 1

    let peaks: [UInt8]
    let duration: TimeInterval

    static func load(from url: URL, bucketCount: Int = defaultBucketCount) throws -> RecordingWaveformData {
        let file = try AVAudioFile(forReading: url)
        let frameTotal = max(Int(file.length), 1)
        let format = file.processingFormat
        let channelCount = max(Int(format.channelCount), 1)
        let capacity: AVAudioFrameCount = 8_192
        var peaks = Array(repeating: Double(0), count: bucketCount)
        var globalFrame = 0

        while file.framePosition < file.length {
            let remaining = Int(file.length - file.framePosition)
            let framesToRead = AVAudioFrameCount(min(Int(capacity), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                break
            }
            try file.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }

            if let channelData = buffer.floatChannelData {
                for frame in 0..<Int(buffer.frameLength) {
                    var samplePeak = Float(0)
                    for channel in 0..<channelCount {
                        samplePeak = max(samplePeak, abs(channelData[channel][frame]))
                    }
                    let bucket = min(
                        Int((Double(globalFrame + frame) / Double(frameTotal)) * Double(bucketCount)),
                        bucketCount - 1
                    )
                    peaks[bucket] = max(peaks[bucket], Double(samplePeak))
                }
            } else if let channelData = buffer.int16ChannelData {
                for frame in 0..<Int(buffer.frameLength) {
                    var samplePeak = Float(0)
                    for channel in 0..<channelCount {
                        samplePeak = max(samplePeak, Float(abs(Int(channelData[channel][frame]))) / Float(Int16.max))
                    }
                    let bucket = min(
                        Int((Double(globalFrame + frame) / Double(frameTotal)) * Double(bucketCount)),
                        bucketCount - 1
                    )
                    peaks[bucket] = max(peaks[bucket], Double(samplePeak))
                }
            }
            globalFrame += Int(buffer.frameLength)
        }

        let maxPeak = max(peaks.max() ?? 0, 0.01)
        let normalized = peaks.map { peak in
            UInt8(min(max(Int((peak / maxPeak * 255).rounded()), 10), 255))
        }
        let duration = Double(file.length) / max(format.sampleRate, 1)
        return RecordingWaveformData(peaks: normalized, duration: duration)
    }

    func encodedCacheData() -> Data {
        var data = Self.cacheMagic
        data.appendLittleEndian(Self.cacheVersion)
        data.appendLittleEndian(UInt16(min(peaks.count, Int(UInt16.max))))
        data.appendLittleEndian(duration.bitPattern)
        data.append(contentsOf: peaks)
        return data
    }

    static func decodeCacheData(_ data: Data) -> RecordingWaveformData? {
        var cursor = data.startIndex
        guard data.count >= cacheMagic.count + 2 + 2 + 8 else { return nil }
        guard data[cursor..<data.index(cursor, offsetBy: cacheMagic.count)] == cacheMagic else { return nil }
        cursor = data.index(cursor, offsetBy: cacheMagic.count)
        guard let version = data.readLittleEndian(UInt16.self, cursor: &cursor),
              version == cacheVersion,
              let count = data.readLittleEndian(UInt16.self, cursor: &cursor),
              let durationBits = data.readLittleEndian(UInt64.self, cursor: &cursor) else {
            return nil
        }
        let peakCount = Int(count)
        guard peakCount > 0, data.distance(from: cursor, to: data.endIndex) >= peakCount else { return nil }
        let peaks = Array(data[cursor..<data.index(cursor, offsetBy: peakCount)])
        return RecordingWaveformData(peaks: peaks, duration: Double(bitPattern: durationBits))
    }
}

private actor RecordingWaveformCache {
    static let shared = RecordingWaveformCache()

    private var memory: [String: RecordingWaveformData] = [:]
    private let fileManager = FileManager.default

    func waveform(for url: URL) throws -> RecordingWaveformData {
        let cacheKey = try cacheKey(for: url)
        if let cached = memory[cacheKey] {
            return cached
        }

        let cacheURL = try cacheURL(for: cacheKey)
        if let data = try? Data(contentsOf: cacheURL),
           let cached = RecordingWaveformData.decodeCacheData(data) {
            memory[cacheKey] = cached
            return cached
        }

        let waveform = try RecordingWaveformData.load(from: url)
        memory[cacheKey] = waveform
        persist(waveform, to: cacheURL)
        return waveform
    }

    private func cacheKey(for url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(modified)"
    }

    private func cacheURL(for cacheKey: String) throws -> URL {
        let directory = AppIdentity.supportDirectoryURL
            .appendingPathComponent("waveform-cache", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined() + ".mwf"
        return directory.appendingPathComponent(filename)
    }

    private func persist(_ waveform: RecordingWaveformData, to cacheURL: URL) {
        do {
            try waveform.encodedCacheData().write(to: cacheURL, options: .atomic)
        } catch {
            fputs("[meeting-recording-player] failed to persist waveform cache: \(error)\n", stderr)
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, cursor: inout Index) -> T? {
        let byteCount = MemoryLayout<T>.size
        guard distance(from: cursor, to: endIndex) >= byteCount else { return nil }
        let next = index(cursor, offsetBy: byteCount)
        let value = self[cursor..<next].withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: T.self)
        }
        cursor = next
        return T(littleEndian: value)
    }
}

struct MeetingRecordingPlayerView: View {
    let recordingPath: String

    @State private var waveform: RecordingWaveformData?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var loadFailed = false

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(player == nil)
            .help(isPlaying ? "Pause recording" : "Play recording")

            Group {
                if let waveform {
                    RecordingWaveformView(
                        peaks: waveform.peaks,
                        progress: progress,
                        onSeek: seek(to:)
                    )
                } else if loadFailed {
                    Text("Recording unavailable")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: MuesliTheme.spacing8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading recording")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 44)

            Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(minWidth: 88, alignment: .trailing)
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.backgroundRaised.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .task(id: recordingPath) {
            await loadRecording()
        }
        .onReceive(timer) { _ in
            guard let player else { return }
            currentTime = player.currentTime
            if !player.isPlaying, isPlaying {
                isPlaying = false
                if player.currentTime >= max(player.duration - 0.1, 0) {
                    currentTime = 0
                    player.currentTime = 0
                }
            }
        }
        .onDisappear {
            player?.stop()
            player = nil
            isPlaying = false
        }
    }

    private var duration: TimeInterval {
        waveform?.duration ?? player?.duration ?? 0
    }

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    @MainActor
    private func loadRecording() async {
        player?.stop()
        player = nil
        waveform = nil
        loadFailed = false
        currentTime = 0
        isPlaying = false

        let url = URL(fileURLWithPath: recordingPath)
        do {
            let loadedWaveform = try await Task.detached(priority: .utility) {
                try await RecordingWaveformCache.shared.waveform(for: url)
            }.value
            let loadedPlayer = try AVAudioPlayer(contentsOf: url)
            loadedPlayer.prepareToPlay()
            waveform = loadedWaveform
            player = loadedPlayer
        } catch {
            loadFailed = true
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.currentTime >= max(player.duration - 0.1, 0) {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
        }
        currentTime = player.currentTime
    }

    private func seek(to progress: CGFloat) {
        guard let player else { return }
        let clamped = min(max(progress, 0), 1)
        player.currentTime = player.duration * Double(clamped)
        currentTime = player.currentTime
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let rounded = max(Int(seconds.rounded()), 0)
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let secs = rounded % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct RecordingWaveformView: View {
    let peaks: [UInt8]
    let progress: CGFloat
    let onSeek: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let sourceCount = peaks.count
                guard sourceCount > 0, size.width > 0, size.height > 0 else { return }
                let spacing: CGFloat = 2
                let barCount = min(sourceCount, max(48, Int(size.width / 4)))
                let barWidth = max(1, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
                let playedX = size.width * progress

                for index in 0..<barCount {
                    let x = CGFloat(index) * (barWidth + spacing)
                    let peak = peakForVisibleBar(index, visibleCount: barCount, sourceCount: sourceCount)
                    let height = max(4, size.height * peak)
                    let y = (size.height - height) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                    let color = x <= playedX ? MuesliTheme.accent : MuesliTheme.textTertiary.opacity(0.24)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color)
                    )
                }

                let playhead = CGRect(x: max(0, min(playedX - 1, size.width - 2)), y: 0, width: 2, height: size.height)
                context.fill(
                    Path(roundedRect: playhead, cornerRadius: 1),
                    with: .color(MuesliTheme.accent)
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        onSeek(value.location.x / proxy.size.width)
                    }
            )
        }
        .frame(minHeight: 36)
        .accessibilityLabel("Recording waveform")
    }

    private func peakForVisibleBar(_ index: Int, visibleCount: Int, sourceCount: Int) -> CGFloat {
        let start = index * sourceCount / visibleCount
        let end = max(start + 1, (index + 1) * sourceCount / visibleCount)
        let maxPeak = peaks[start..<min(end, sourceCount)].max() ?? 10
        return CGFloat(maxPeak) / 255
    }
}
