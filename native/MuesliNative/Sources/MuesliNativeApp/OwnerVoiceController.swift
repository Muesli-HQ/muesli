@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class OwnerVoiceController {
    private(set) var profile: OwnerVoiceProfile?
    private(set) var generation = OwnerVoiceGeneration()
    private(set) var isRecording = false
    private(set) var acceptedSpeechSeconds: Double = 0
    private(set) var status = "No voice enrolled"
    private let store: VoiceProfileStore?
    private let coordinator: TranscriptionCoordinator
    private let captureIsActive: () -> Bool
    private let onChange: (UInt64) -> Void
    private var attemptGeneration = OwnerVoiceGeneration()
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var enrollment: OwnerVoiceEnrollment?

    init(coordinator: TranscriptionCoordinator, supportDirectory: URL,
         captureIsActive: @escaping () -> Bool, onChange: @escaping (UInt64) -> Void) {
        self.coordinator = coordinator
        self.captureIsActive = captureIsActive
        self.onChange = onChange
        do {
            let store = try VoiceProfileStore(supportDirectory: supportDirectory)
            let loadedProfile = try store.loadStored()
            self.store = store
            self.profile = loadedProfile
            self.status = loadedProfile == nil ? "No usable voice profile. Record your voice to enroll." : "Voice enrolled on this device"
        } catch {
            self.store = nil
            self.profile = nil
            self.status = "Voice profile storage is unavailable. Try again after restarting."
        }
        let token = generation.begin()
        let initial = profile
        Task { await coordinator.setOwnerVoiceProfile(initial, generation: token) }
    }

    func refreshModelCompatibility() async {
        guard let enrolled = profile, !isRecording else { return }
        await coordinator.preloadDiarizer()
        let identity = await coordinator.ownerVoiceModelIdentity()
        guard profile == enrolled, !isRecording else { return }
        if identity == nil {
            status = "Voice recognition is unavailable until its models load. Transcription can still continue."
        } else if identity != enrolled.modelIdentity {
            status = "This voice profile uses different models. Replace your voice profile to enroll again."
        } else {
            status = "Voice enrolled on this device"
        }
    }

    func record() {
        guard !captureIsActive(), !isRecording, let store else { return }
        cancel()
        let token = attemptGeneration.begin()
        isRecording = true
        status = "Preparing microphone…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let permitted = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard permitted, !self.captureIsActive(), self.attemptGeneration.accepts(token) else {
                    throw OwnerVoiceEnrollmentError.unavailable
                }
                await self.coordinator.preloadMeetingVAD()
                await self.coordinator.preloadDiarizer()
                try Task.checkCancellation()
                guard let identity = await self.coordinator.ownerVoiceModelIdentity(),
                      !self.captureIsActive(), self.attemptGeneration.accepts(token) else {
                    throw OwnerVoiceEnrollmentError.unavailable
                }
                let enrollment = OwnerVoiceEnrollment(extractor: OwnerVoiceExtractor(coordinator: self.coordinator), modelIdentity: identity)
                self.enrollment = enrollment
                enrollment.begin()
                let start = Date()
                self.status = "Speak naturally. Progress counts clear speech."
                self.deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.attemptGeneration.accepts(token) else { return }
                    self.cancel()
                    self.status = OwnerVoiceEnrollmentError.insufficientSpeech.localizedDescription
                }
                while self.attemptGeneration.accepts(token), !self.captureIsActive() {
                    try enrollment.checkDeadline(elapsed: Date().timeIntervalSince(start))
                    let url = store.enrollmentDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
                    defer { try? FileManager.default.removeItem(at: url) }
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw OwnerVoiceEnrollmentError.unavailable
                    }
                    let recorder = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    ])
                    self.recorder = recorder
                    guard recorder.prepareToRecord() else { throw OwnerVoiceEnrollmentError.unavailable }
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    guard recorder.record() else { throw OwnerVoiceEnrollmentError.unavailable }
                    try await Task.sleep(for: .seconds(5))
                    recorder.stop()
                    self.recorder = nil
                    try Task.checkCancellation()
                    let samples = try AudioConverter().resampleAudioFile(url)
                    try FileManager.default.removeItem(at: url)
                    let candidate = try await enrollment.accept(samples: samples, elapsed: Date().timeIntervalSince(start))
                    guard self.attemptGeneration.accepts(token), !self.captureIsActive() else { throw CancellationError() }
                    self.acceptedSpeechSeconds = enrollment.acceptedSpeechSeconds
                    if let candidate {
                        // No await between token validation, atomic save, and publication.
                        try store.cleanEnrollmentArtifacts()
                        try store.replace(candidate)
                        self.profile = candidate
                        self.finishAttempt()
                        self.status = "Voice enrolled on this device"
                        let generation = self.generation.begin()
                        await self.coordinator.setOwnerVoiceProfile(candidate, generation: generation)
                        guard self.generation.accepts(generation) else { return }
                        self.onChange(generation)
                        return
                    }
                }
                throw CancellationError()
            } catch is CancellationError {
                if self.attemptGeneration.accepts(token) { self.cancel() }
            } catch {
                if self.attemptGeneration.accepts(token) {
                    self.finishAttempt()
                    self.status = (error as? OwnerVoiceEnrollmentError)?.localizedDescription
                        ?? "Enrollment failed. Your previous profile is unchanged. Please try again."
                }
            }
        }
    }

    func cancelForCaptureStart() { cancel() }
    func cancel() {
        attemptGeneration.invalidate()
        task?.cancel()
        task = nil
        finishAttempt()
        status = profile == nil ? "No voice enrolled" : "Voice enrolled on this device"
    }

    func delete() {
        cancel()
        let token = generation.begin()
        do {
            guard let store else { throw OwnerVoiceProfileError.invalidProfile }
            try store.delete()
            profile = nil
            status = "Voice profile deleted"
            Task { await coordinator.setOwnerVoiceProfile(nil, generation: token) }
        } catch {
            status = "Could not delete the stored profile. Please retry."
            let currentProfile = profile
            Task { await coordinator.setOwnerVoiceProfile(currentProfile, generation: token) }
        }
        onChange(token)
    }

    private func finishAttempt() {
        recorder?.stop()
        recorder = nil
        deadline?.cancel()
        deadline = nil
        enrollment?.cancel()
        enrollment = nil
        isRecording = false
        acceptedSpeechSeconds = 0
        try? store?.cleanEnrollmentArtifacts()
    }
}

struct OwnerVoiceSettingsView: View {
    let voice: OwnerVoiceController
    let captureActive: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(voice.status).font(.callout)
            if voice.isRecording {
                ProgressView(value: min(voice.acceptedSpeechSeconds, 20), total: 20)
                Text("\(Int(voice.acceptedSpeechSeconds)) of 20 seconds of clear speech").font(.caption)
                Button("Cancel") { voice.cancel() }
            } else {
                HStack {
                    Button(voice.profile == nil ? "Record your voice" : "Replace voice") { voice.record() }
                        .disabled(captureActive)
                    if voice.profile != nil { Button("Delete voice", role: .destructive) { voice.delete() } }
                }
                Text("Stored only on this device. Record in a quiet room with only your voice.").font(.caption)
                if captureActive { Text("Finish recording before enrolling your voice.").font(.caption) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await voice.refreshModelCompatibility() }
    }
}
