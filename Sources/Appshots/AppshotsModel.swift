import AppKit
import ApplicationServices
import Foundation
@preconcurrency import KWWKComputerUseCore

@MainActor
final class AppshotsModel: ObservableObject {
    @Published var recentCaptures: [AppshotRecord] = []
    @Published var statusMessage = "Ready"
    @Published var isCapturing = false
    @Published var hasAccessibilityPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hotKey: AppshotsHotKey {
        didSet {
            guard oldValue != hotKey else { return }
            UserDefaults.standard.set(hotKey.encodedString, forKey: Self.hotKeyDefaultsKey)
            statusMessage = "Hotkey: \(hotKey.displayText)"
        }
    }

    weak var frontmostTracker: FrontmostAppTracker?
    var playCaptureAnimation: ((AppshotRecord) -> Void)?

    private let store = AppshotStore()
    private let maxRecentCaptures = 10
    private static let hotKeyDefaultsKey = "AppshotsHotKey"

    init() {
        let rawHotKey = UserDefaults.standard.string(forKey: Self.hotKeyDefaultsKey)
        hotKey = AppshotsHotKey.decode(from: rawHotKey)
    }

    var latestCapture: AppshotRecord? {
        recentCaptures.first
    }

    func startSession() {
        do {
            try store.ensureRootDirectory()
            try store.clearLatestCaptureManifest()
            recentCaptures = []
            statusMessage = "Ready"
        } catch {
            recentCaptures = []
            statusMessage = error.localizedDescription
        }
    }

    func endSession() {
        for record in recentCaptures {
            try? store.removeCapture(record)
        }
        try? store.clearLatestCaptureManifest()
        recentCaptures = []
    }

    func refreshPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibilityPermission() {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecordingPermission() {
        hasScreenRecordingPermission = CGRequestScreenCaptureAccess()
    }

    func captureFrontmostApp() {
        guard isCapturing == false else { return }

        guard let target = frontmostTracker?.captureTarget() else {
            statusMessage = "No frontmost app to capture"
            return
        }

        isCapturing = true
        statusMessage = "Capturing \(target.name)..."

        Task.detached(priority: .userInitiated) {
            do {
                let record = try AppshotCaptureService.capture(target: target)
                await MainActor.run {
                    self.insertRecentCapture(record)
                    self.copyAppshotMarkupToPasteboard(for: record)
                    self.playCaptureAnimation?(record)
                    self.isCapturing = false
                    self.statusMessage = "Captured \(record.appName) and copied markup"
                    self.refreshPermissions()
                    NSApp.requestUserAttention(.informationalRequest)
                }
            } catch {
                await MainActor.run {
                    self.isCapturing = false
                    self.statusMessage = error.localizedDescription
                    self.refreshPermissions()
                }
            }
        }
    }

    func copyAppshotMarkup(for record: AppshotRecord) {
        copyAppshotMarkupToPasteboard(for: record)
        statusMessage = "Copied app-shot markup"
    }

    private func copyAppshotMarkupToPasteboard(for record: AppshotRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.appshotMarkup, forType: .string)
    }

    private func insertRecentCapture(_ record: AppshotRecord) {
        recentCaptures.removeAll { $0.id == record.id }
        recentCaptures.insert(record, at: 0)

        let overflow = Array(recentCaptures.dropFirst(maxRecentCaptures))
        recentCaptures = Array(recentCaptures.prefix(maxRecentCaptures))

        for staleRecord in overflow {
            try? store.removeCapture(staleRecord)
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
