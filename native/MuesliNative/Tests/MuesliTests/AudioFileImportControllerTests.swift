import Testing
import Foundation
import AVFoundation
import FluidAudio
import MuesliCore
@testable import MuesliNativeApp

@Suite("AudioFileImportController")
struct AudioFileImportControllerTests {

    // MARK: - WAV Conversion Tests

    @Test("convertToWAV produces valid 16kHz mono WAV from valid audio")
    func convertToWAVProducesValidOutput() async throws {
        let sourceURL = try createTestAudioFile(duration: 2.0, sampleRate: 44100, channels: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let (wavURL, duration) = try await AudioFileImportController.convertToWAV(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #expect(duration > 0)
        #expect(duration <= 2.5)  // allow small tolerance

        // Verify the output is a valid WAV with expected format
        let file = try AVAudioFile(forReading: wavURL)
        let format = file.fileFormat
        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatInt16)
        #expect(file.length > 0)
    }

    @Test("convertToWAV throws noAudioTracks for file without audio")
    func convertToWAVThrowsForNoAudio() async throws {
        // Create a minimal file that has no audio tracks (just a temp empty file)
        let tempDir = FileManager.default.temporaryDirectory
        let emptyURL = tempDir.appendingPathComponent("empty_test_\(UUID().uuidString).txt")
        try "not audio".write(to: emptyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: emptyURL) }

        do {
            _ = try await AudioFileImportController.convertToWAV(sourceURL: emptyURL)
            Issue.record("Expected convertToWAV to throw for non-audio file")
        } catch let error as AudioFileImportController.ImportError {
            #expect(error == .noAudioTracks || error.localizedDescription.contains("audio"))
        } catch {
            // AVAsset may throw other errors for non-media files, which is acceptable
        }
    }

    @Test("convertToWAV handles mono source audio")
    func convertToWAVHandlesMonoSource() async throws {
        let sourceURL = try createTestAudioFile(duration: 1.0, sampleRate: 48000, channels: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let (wavURL, duration) = try await AudioFileImportController.convertToWAV(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #expect(duration > 0)
        let file = try AVAudioFile(forReading: wavURL)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 16000)
    }

    @Test("convertToWAV handles already normalized Muesli WAV")
    func convertToWAVHandlesAlreadyNormalizedWAV() async throws {
        let sourceURL = try createTestAudioFile(duration: 1.0, sampleRate: 16000, channels: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let (wavURL, duration) = try await AudioFileImportController.convertToWAV(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #expect(duration > 0.9)
        let file = try AVAudioFile(forReading: wavURL)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
    }

    @Test("convertToWAV handles short audio clips")
    func convertToWAVHandlesShortAudio() async throws {
        let sourceURL = try createTestAudioFile(duration: 0.5, sampleRate: 44100, channels: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let (wavURL, duration) = try await AudioFileImportController.convertToWAV(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #expect(duration > 0)
        #expect(duration < 1.0)
    }

    @Test("supported file URL validation accepts only importable audio extensions")
    func supportedFileURLValidation() {
        #expect(AudioFileImportController.isSupportedFileURL(URL(fileURLWithPath: "/tmp/test.wav")))
        #expect(AudioFileImportController.isSupportedFileURL(URL(fileURLWithPath: "/tmp/test.MP3")))
        #expect(!AudioFileImportController.isSupportedFileURL(URL(fileURLWithPath: "/tmp/test.txt")))
    }

    // MARK: - Speaker Formatting Tests

    @Test("formatTranscriptWithSpeakers returns raw text when no segments")
    func formatTranscriptWithSpeakersNoSegments() {
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            rawText: "Hello world",
            diarizationSegments: [],
            duration: 10.0
        )
        #expect(result == "Hello world")
    }

    @Test("formatTranscriptWithSpeakers returns raw text for single speaker")
    func formatTranscriptWithSpeakersSingleSpeaker() {
        let segments = [
            makeDiarSeg(speakerId: "SPEAKER_0", start: 0, end: 5),
            makeDiarSeg(speakerId: "SPEAKER_0", start: 5, end: 10),
        ]
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            rawText: "Hello world",
            diarizationSegments: segments,
            duration: 10.0
        )
        #expect(result == "Hello world")
    }

    @Test("formatTranscriptWithSpeakers adds speaker labels for multiple speakers")
    func formatTranscriptWithSpeakersMultipleSpeakers() {
        let segments = [
            makeDiarSeg(speakerId: "SPEAKER_0", start: 0, end: 5),
            makeDiarSeg(speakerId: "SPEAKER_1", start: 5, end: 10),
        ]
        let transcription = SpeechTranscriptionResult(
            text: "Hello world\nHi there",
            segments: [
                SpeechSegment(start: 0, end: 4, text: "Hello world"),
                SpeechSegment(start: 6, end: 9, text: "Hi there"),
            ]
        )
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            transcription: transcription,
            diarizationSegments: segments,
            meetingStart: localMidnight()
        )
        #expect(result.contains("Speaker 1: Hello world"))
        #expect(result.contains("Speaker 2: Hi there"))
        #expect(!result.contains("## Speaker Segments"))
    }

    @Test("formatTranscriptWithSpeakers falls back to raw text without ASR segments")
    func formatTranscriptWithSpeakersFallsBackWithoutASRSegments() {
        let segments = [
            makeDiarSeg(speakerId: "SPEAKER_0", start: 0, end: 5),
            makeDiarSeg(speakerId: "SPEAKER_1", start: 5, end: 10),
        ]
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            transcription: SpeechTranscriptionResult(text: "Hello world", segments: []),
            diarizationSegments: segments,
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result == "Hello world")
    }

    @Test("formatTranscriptWithSpeakers preserves timestamped text")
    func formatTranscriptWithSpeakersPreservesTimestampedText() {
        let segments = [
            makeDiarSeg(speakerId: "SPEAKER_0", start: 0, end: 5),
            makeDiarSeg(speakerId: "SPEAKER_1", start: 5, end: 10),
        ]
        let timestampedText = "[00:00] Speaker 1: Hello\n[00:05] Speaker 2: Hi there"
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            rawText: timestampedText,
            diarizationSegments: segments,
            duration: 10.0
        )
        // Should preserve the original timestamped text
        #expect(result == timestampedText)
    }

    // MARK: - Time Formatting Tests

    @Test("format time interval under one hour")
    func formatTimeIntervalUnderHour() {
        // Test via formatTranscriptWithSpeakers which uses internal formatting
        let segments = [
            makeDiarSeg(speakerId: "SPEAKER_0", start: 65.0, end: 125.0),
            makeDiarSeg(speakerId: "SPEAKER_1", start: 125.0, end: 185.0),
        ]
        let transcription = SpeechTranscriptionResult(
            text: "First\nSecond",
            segments: [
                SpeechSegment(start: 65, end: 66, text: "First"),
                SpeechSegment(start: 125, end: 126, text: "Second"),
            ]
        )
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            transcription: transcription,
            diarizationSegments: segments,
            meetingStart: localMidnight()
        )
        #expect(result.contains("00:01:05"))
        #expect(result.contains("00:02:05"))
    }

    @Test("format time interval over one hour")
    func formatTimeIntervalOverHour() {
        let segments = [
            makeDiarSeg(speakerId: "SPEAKER_0", start: 3661.0, end: 3720.0),
            makeDiarSeg(speakerId: "SPEAKER_1", start: 7200.0, end: 7260.0),
        ]
        let transcription = SpeechTranscriptionResult(
            text: "First\nSecond",
            segments: [
                SpeechSegment(start: 3661, end: 3662, text: "First"),
                SpeechSegment(start: 7200, end: 7201, text: "Second"),
            ]
        )
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            transcription: transcription,
            diarizationSegments: segments,
            meetingStart: localMidnight()
        )
        #expect(result.contains("01:01:01"))
        #expect(result.contains("02:00:00"))
    }

    @Test("raw-text compatibility formatter preserves text without timestamped ASR segments")
    func rawTextCompatibilityFormatterPreservesText() {
        let segments = [
            makeDiarSeg(speakerId: "SPEAKER_0", start: 0, end: 5),
            makeDiarSeg(speakerId: "SPEAKER_1", start: 5, end: 10),
        ]
        let result = AudioFileImportController.formatTranscriptWithSpeakers(
            rawText: "Test transcript",
            diarizationSegments: segments,
            duration: 10.0
        )
        #expect(result.contains("Test transcript"))
    }

    // MARK: - Helpers

    /// Creates a test audio file with a sine wave tone.
    private func createTestAudioFile(
        duration: TimeInterval,
        sampleRate: Double,
        channels: Int
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audio_\(UUID().uuidString).wav")

        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
        }
        buffer.frameLength = frameCount

        // Fill with a 440Hz sine wave
        let frequency: Float = 440.0
        if let channelData = buffer.int16ChannelData {
            for frame in 0..<Int(frameCount) {
                let sample = Int16(sin(2.0 * .pi * frequency * Float(frame) / Float(sampleRate)) * 16000)
                for ch in 0..<channels {
                    channelData[ch][frame] = sample
                }
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        try file.write(from: buffer)

        return url
    }

    private func makeDiarSeg(speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }

    private func localMidnight() -> Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 0))
    }
}
