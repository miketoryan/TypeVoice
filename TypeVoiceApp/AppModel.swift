import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: TypeVoiceStatus = SharedStore.status
    @Published private(set) var isServiceReady = SharedStore.isServiceReady()
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String? = SharedStore.lastError
    @Published private(set) var apiKeyConfigured = !(KeychainStore.loadAPIKey() ?? "").isEmpty

    private let audioService = AudioStandbyService()
    private var observations: [DarwinObservation] = []
    private var expiryTimer: Timer?
    private var processingTask: Task<Void, Never>?

    init() {
        audioService.onExpired = { [weak self] in
            Task { @MainActor in self?.disarm() }
        }
        audioService.onInterrupted = { [weak self] in
            Task { @MainActor in
                self?.fail("Microphone session was interrupted.")
                self?.audioService.disarm()
                self?.refresh()
            }
        }

        observations = [
            DarwinBus.observe(.startRecording) { [weak self] in
                DispatchQueue.main.async {
                    self?.handleStartRequest()
                }
            },
            DarwinBus.observe(.stopRecording) { [weak self] in
                DispatchQueue.main.async {
                    self?.stopRecording()
                }
            },
            DarwinBus.observe(.cancelRecording) { [weak self] in
                DispatchQueue.main.async {
                    self?.cancelRecording()
                }
            }
        ]

        refresh()
    }

    deinit {
        expiryTimer?.invalidate()
        processingTask?.cancel()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("API key cannot be empty.")
            return
        }

        do {
            try KeychainStore.saveAPIKey(trimmed)
            apiKeyConfigured = true
            lastError = nil
            SharedStore.setError(nil)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func arm() async {
        guard apiKeyConfigured else {
            fail("Add an OpenAI API key first.")
            return
        }

        let granted = await audioService.requestMicrophonePermission()
        guard granted else {
            fail("Microphone permission is required.")
            return
        }

        do {
            let expiry = Date().addingTimeInterval(TimeInterval(SharedStore.quickMinutes * 60))
            try audioService.arm(until: expiry)
            SharedStore.markServiceReady(expiresAt: expiry)
            SharedStore.setError(nil)
            status = .ready
            lastError = nil
            isServiceReady = true
            DarwinBus.post(.serviceChanged)
            DarwinBus.post(.statusChanged)
            installExpiryTimer()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func disarm() {
        processingTask?.cancel()
        processingTask = nil
        audioService.cancelRecording(keepWarm: false)
        SharedStore.status = .idle
        SharedStore.clearStartRequest()
        status = .idle
        isServiceReady = false
        expiryTimer?.invalidate()
        expiryTimer = nil
        DarwinBus.post(.serviceChanged)
        DarwinBus.post(.statusChanged)
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "typevoice" else { return }
        guard url.host?.lowercased() == "prepare" else { return }

        Task {
            if !SharedStore.isServiceReady() || !audioService.isRunning {
                await arm()
            }
            if SharedStore.pendingStartRequestID != nil, audioService.isRunning {
                handleStartRequest()
            }
        }
    }

    func appBecameActive() {
        refresh()
    }

    func refresh() {
        status = SharedStore.status
        isServiceReady = SharedStore.isServiceReady() && audioService.isRunning
        lastError = SharedStore.lastError
    }

    private func handleStartRequest() {
        guard SharedStore.pendingStartRequestID != nil else { return }
        guard !audioService.isRecording else { return }
        guard audioService.isRunning, SharedStore.isServiceReady() else {
            return
        }

        do {
            _ = try audioService.beginRecording()
            SharedStore.status = .recording
            SharedStore.setError(nil)
            status = .recording
            lastError = nil
            SharedStore.clearStartRequest()
            DarwinBus.post(.statusChanged)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func stopRecording() {
        guard audioService.isRecording else { return }
        guard let fileURL = audioService.finishRecording(keepWarm: true) else {
            fail("Recording file was not available.")
            return
        }

        SharedStore.status = .transcribing
        status = .transcribing
        DarwinBus.post(.statusChanged)

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.process(fileURL: fileURL)
        }
    }

    private func cancelRecording() {
        audioService.cancelRecording(keepWarm: true)
        SharedStore.status = SharedStore.isServiceReady() ? .ready : .idle
        SharedStore.clearStartRequest()
        refresh()
        DarwinBus.post(.statusChanged)
    }

    private func process(fileURL: URL) async {
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            fail("OpenAI API key is missing.")
            return
        }

        let client = OpenAIClient(
            apiKey: apiKey,
            baseURL: SharedStore.apiBaseURL,
            transcriptionModel: SharedStore.transcriptionModel,
            cleanupModel: SharedStore.cleanupModel
        )

        do {
            let raw = try await client.transcribe(fileURL: fileURL)
            lastTranscript = raw

            SharedStore.status = .polishing
            status = .polishing
            DarwinBus.post(.statusChanged)

            let finalText: String
            do {
                finalText = try await client.cleanup(raw)
            } catch {
                // Dictation should still be usable if cleanup fails.
                finalText = raw
                SharedStore.setError("Cleanup failed; inserted raw transcript. \(error.localizedDescription)")
            }

            guard !Task.isCancelled else { return }

            _ = SharedStore.publishResult(finalText)
            lastTranscript = finalText
            SharedStore.status = SharedStore.isServiceReady() ? .ready : .idle
            status = SharedStore.status
            isServiceReady = SharedStore.isServiceReady()
            DarwinBus.post(.resultReady)
            DarwinBus.post(.statusChanged)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        SharedStore.setError(message)
        SharedStore.status = .failed
        status = .failed
        lastError = message
        DarwinBus.post(.statusChanged)
    }

    private func installExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ready = SharedStore.isServiceReady()
                self.isServiceReady = ready && self.audioService.isRunning
                if !ready, !self.audioService.isRecording {
                    self.disarm()
                }
            }
        }
    }
}
