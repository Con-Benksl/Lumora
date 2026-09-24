import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

@MainActor
final class MusicManager: ObservableObject {
    @Published private(set) var playbackState = PlaybackState()
    @Published private(set) var albumArt: NSImage?
    @Published private(set) var artworkGradient: [NSColor] = [
        NSColor.white.withAlphaComponent(0.95),
        NSColor.white.withAlphaComponent(0.75),
        NSColor.white.withAlphaComponent(0.55)
    ]
    @Published private(set) var hasArtworkGradient = false
    @Published private(set) var sourceApp: SourceApp?

    private var cancellables = Set<AnyCancellable>()
    private var sourceAppCache: [String: SourceApp] = [:]
    private let controller: MediaControllerProtocol
    private var artworkTask: Task<Void, Never>?
    nonisolated private static let ciContext = CIContext(options: nil)

    struct SourceApp {
        let bundleIdentifier: String
        let displayName: String
        let icon: NSImage?
    }

    nonisolated private static let defaultArtworkGradient: [NSColor] = [
        NSColor.white.withAlphaComponent(0.95),
        NSColor.white.withAlphaComponent(0.75),
        NSColor.white.withAlphaComponent(0.55)
    ]

    private static let sourceAppDisplayNameOverrides: [String: String] = [
        "com.apple.Music": "Apple Music",
        "com.tencent.qqmusic": "QQ Music",
        "com.tencent.qqmusicmac": "QQ Music",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.microsoftedge": "Microsoft Edge"
    ]

    init(controller: MediaControllerProtocol? = nil) {
        self.controller = controller ?? NowPlayingController()

        self.controller.playbackStatePublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }

                let previousState = self.playbackState
                self.playbackState = state
                // Elapsed-time and play/pause updates reuse the decoded artwork.
                if state.artworkData != previousState.artworkData {
                    self.updateArtwork(state.artworkData)
                }
                if state.bundleIdentifier != previousState.bundleIdentifier {
                    self.sourceApp = self.resolveSourceApp(bundleIdentifier: state.bundleIdentifier)
                }
            }
            .store(in: &cancellables)

        if controller != nil {
            self.controller.refresh()
        }
    }

    deinit { artworkTask?.cancel() }

    private func updateArtwork(_ data: Data?) {
        artworkTask?.cancel()
        guard let data else {
            artworkTask = nil
            albumArt = nil
            artworkGradient = Self.defaultArtworkGradient
            hasArtworkGradient = false
            return
        }

        artworkTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = Self.prepareArtwork(data)
            guard !Task.isCancelled else { return }
            await self?.applyArtwork(result, data: data)
        }
    }

    private func applyArtwork(_ result: (image: CGImage?, colors: [NSColor], isExtracted: Bool), data: Data) {
        // A cancelled task may already be waiting for the main actor when a new song arrives.
        guard !Task.isCancelled, playbackState.artworkData == data else { return }
        albumArt = result.image.map { NSImage(cgImage: $0, size: .zero) }
        artworkGradient = result.colors
        hasArtworkGradient = result.isExtracted
        artworkTask = nil
    }

    nonisolated private static func prepareArtwork(_ data: Data) -> (image: CGImage?, colors: [NSColor], isExtracted: Bool) {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            // The largest cover is 76 pt. Decode enough pixels for Retina before extracting colors;
            // the original bytes remain in playbackState for equality checks and media state.
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary),
            !Task.isCancelled
        else { return (nil, defaultArtworkGradient, false) }

        let gradient = gradientColors(from: CIImage(cgImage: thumbnail))
        return (thumbnail, gradient.colors, gradient.isExtractedFromArtwork)
    }

    var isVisible: Bool {
        playbackState.hasDisplayableContent
    }

    var fallbackSymbolName: String {
        playbackState.isPlaying ? "music.note" : "music.note.list"
    }

    var edgeGlowGradient: [NSColor] {
        hasArtworkGradient ? artworkGradient : [
            NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 0.95),
            NSColor(red: 0.6, green: 0.4, blue: 1.0, alpha: 0.85),
            NSColor(red: 0.4, green: 0.85, blue: 1.0, alpha: 0.7)
        ]
    }

    var progressFraction: Double {
        guard playbackState.duration > 0 else { return 0 }
        return min(max(playbackState.currentTime / playbackState.duration, 0), 1)
    }

    func refresh() { controller.refresh() }
    func restartStreaming() {
        controller.restartStreaming()
        // refresh() is called inside controller.restartStreaming()
    }
    func togglePlayPause(displayedTime: TimeInterval? = nil) {
        controller.togglePlayPause(displayedTime: displayedTime)
    }
    func nextTrack() { controller.nextTrack() }
    func previousTrack() { controller.previousTrack() }
    func openSourceApp() { controller.openSourceApp() }
    /// Seeking is disabled because the system elapsed-time command currently fails.
    /// See NowPlayingController for details.
    func seekTo(_ time: TimeInterval) {}

    private func resolveSourceApp(bundleIdentifier: String?) -> SourceApp? {
        let trimmedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleIdentifier = trimmedBundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }

        if let cached = sourceAppCache[bundleIdentifier] {
            return cached
        }

        guard let displayName = resolveDisplayName(for: bundleIdentifier) else {
            return nil
        }

        let resolved = SourceApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            icon: resolveIcon(for: bundleIdentifier)
        )
        sourceAppCache[bundleIdentifier] = resolved
        return resolved
    }

    private func resolveDisplayName(for bundleIdentifier: String) -> String? {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            if let resolvedName = resolvedBundleDisplayName(at: applicationURL, bundleIdentifier: bundleIdentifier) {
                return resolvedName
            }
        }

        return fallbackDisplayName(for: bundleIdentifier).map {
            overrideDisplayNameIfNeeded($0, bundleIdentifier: bundleIdentifier)
        }
    }

    private func resolveIcon(for bundleIdentifier: String) -> NSImage? {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return nil
    }

    private func resolvedBundleDisplayName(at applicationURL: URL, bundleIdentifier: String) -> String? {
        if let bundle = Bundle(url: applicationURL) {
            let bundleKeys = ["CFBundleDisplayName", "CFBundleName"]
            for key in bundleKeys {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return overrideDisplayNameIfNeeded(trimmed, bundleIdentifier: bundleIdentifier)
                    }
                }
            }
        }
        return nil
    }

    private func overrideDisplayNameIfNeeded(_ displayName: String, bundleIdentifier: String) -> String {
        Self.sourceAppDisplayNameOverrides[bundleIdentifier] ?? displayName
    }

    private func runningApplication(for bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private func fallbackDisplayName(for bundleIdentifier: String) -> String? {
        let rawName = bundleIdentifier
            .split(separator: ".")
            .last
            .map(String.init) ?? bundleIdentifier

        let normalized = rawName
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return nil
        }

        let strippedSuffixes = [" mac", " stable", " beta", " canary", " insiders"]
        let cleaned = strippedSuffixes.reduce(normalized) { partialResult, suffix in
            partialResult.hasSuffix(suffix) ? String(partialResult.dropLast(suffix.count)) : partialResult
        }

        let displayName = cleaned
            .split(separator: " ")
            .map { segment in segment.prefix(1).uppercased() + segment.dropFirst() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return displayName.isEmpty ? nil : displayName
    }

    nonisolated private static func gradientColors(from ciImage: CIImage) -> (colors: [NSColor], isExtractedFromArtwork: Bool) {
        let extent = ciImage.extent
        guard !extent.isEmpty else {
            return (Self.defaultArtworkGradient, false)
        }

        let regions = [
            CGRect(x: extent.minX, y: extent.minY, width: extent.width * 0.5, height: extent.height),
            CGRect(x: extent.minX + extent.width * 0.25, y: extent.minY, width: extent.width * 0.5, height: extent.height),
            CGRect(x: extent.minX + extent.width * 0.5, y: extent.minY, width: extent.width * 0.5, height: extent.height)
        ]

        let extracted = regions.compactMap { averageColor(in: ciImage, region: $0) }.map(normalizedGradientColor(_:))
        if extracted.count >= 3 {
            return (extracted, true)
        }

        if let single = averageColor(in: ciImage, region: extent) {
            let base = normalizedGradientColor(single)
            return ([
                adjustedColor(base, saturation: 1.15, brightness: 1.18, alpha: 0.95),
                adjustedColor(base, saturation: 1.0, brightness: 1.0, alpha: 0.8),
                adjustedColor(base, saturation: 0.9, brightness: 0.78, alpha: 0.65)
            ], true)
        }

        return (Self.defaultArtworkGradient, false)
    }

    nonisolated private static func averageColor(in image: CIImage, region: CGRect) -> NSColor? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image.cropped(to: region)
        filter.extent = region

        guard let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return NSColor(
            calibratedRed: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: 1
        )
    }

    nonisolated private static func normalizedGradientColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let adjustedSaturation = max(0.35, min(saturation * 1.18 + 0.08, 0.95))
        let adjustedBrightness = max(0.5, min(brightness * 1.08 + 0.1, 0.98))

        let base = NSColor(calibratedHue: hue, saturation: adjustedSaturation, brightness: adjustedBrightness, alpha: 1)
        return adjustedColor(base, saturation: 1.0, brightness: 1.0, alpha: 0.92)
    }

    nonisolated private static func adjustedColor(_ color: NSColor, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color.withAlphaComponent(alpha) }

        var hue: CGFloat = 0
        var currentSaturation: CGFloat = 0
        var currentBrightness: CGFloat = 0
        var currentAlpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &currentSaturation, brightness: &currentBrightness, alpha: &currentAlpha)

        return NSColor(
            calibratedHue: hue,
            saturation: min(max(currentSaturation * saturation, 0), 1),
            brightness: min(max(currentBrightness * brightness, 0), 1),
            alpha: alpha
        )
    }
}
