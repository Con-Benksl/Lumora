#!/usr/bin/env python3
"""Drive the real MusicManager publisher without starting a media session."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
if not sdk.exists():
    sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())

check = r'''
import AppKit
import Combine
import Foundation
import ImageIO

// Test-only scheduling gate around the real worker, with no hooks in the app build.
nonisolated final class ArtworkProbe: @unchecked Sendable {
    static let shared = ArtworkProbe()
    private let lock = NSLock()
    private var heldData: Data?
    private var waiting = false
    private var started = 0
    private var completed = 0
    private var lastDuration: Double = 0
    let release = DispatchSemaphore(value: 0)
    var counts: (started: Int, completed: Int, waiting: Bool, duration: Double) {
        lock.withLock { (started, completed, waiting, lastDuration) }
    }
    func hold(_ data: Data) { lock.withLock { heldData = data } }
    func begin() -> Date {
        precondition(!Thread.isMainThread, "artwork decoding must run off the main thread")
        lock.withLock { started += 1 }
        return Date()
    }
    func finish(_ data: Data, since start: Date) {
        precondition(!Thread.isMainThread, "gradient extraction must run off the main thread")
        let shouldWait = lock.withLock {
            lastDuration = Date().timeIntervalSince(start)
            guard heldData == data else { return false }
            heldData = nil
            waiting = true
            return true
        }
        if shouldWait { precondition(release.wait(timeout: .now() + 5) == .success) }
        lock.withLock { waiting = false; completed += 1 }
    }
}

@MainActor final class MockMediaController: MediaControllerProtocol {
    let subject: CurrentValueSubject<PlaybackState, Never>
    var refreshCount = 0
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { subject.eraseToAnyPublisher() }
    init() { subject = .init(PlaybackState()) }
    init(state: PlaybackState) { subject = .init(state) }
    func refresh() { refreshCount += 1 }
    func restartStreaming() {}
    func togglePlayPause(displayedTime: TimeInterval?) {}
    func nextTrack() {}
    func previousTrack() {}
    func openSourceApp() {}
}
typealias NowPlayingController = MockMediaController

@main struct Check {
    @MainActor static func pump(_ duration: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
    @MainActor static func waitFor(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { pump(0.002) }
        precondition(condition(), message)
    }
    @MainActor static func syntheticPNG(size: Int, red: CGFloat, blue: CGFloat) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        for x in 0..<4 { for y in 0..<4 { bitmap.setColor(red, atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        var state = PlaybackState(bundleIdentifier: "com.apple.Music", isPlaying: true,
            title: "Track", currentTime: 1, duration: 180, artworkData: png)
        let controller = MockMediaController(state: state)
        let manager = MusicManager(controller: controller)
        var subscriptions = Set<AnyCancellable>()
        var artUpdates = 0, gradientUpdates = 0, sourceUpdates = 0, stateUpdates = 0
        manager.$albumArt.dropFirst().sink { _ in artUpdates += 1 }.store(in: &subscriptions)
        manager.$artworkGradient.dropFirst().sink { _ in gradientUpdates += 1 }.store(in: &subscriptions)
        manager.$sourceApp.dropFirst().sink { _ in sourceUpdates += 1 }.store(in: &subscriptions)
        manager.$playbackState.dropFirst().sink { _ in stateUpdates += 1 }.store(in: &subscriptions)
        waitFor("first artwork must finish", { manager.albumArt != nil })
        assert(controller.refreshCount == 1 && manager.playbackState == state)
        assert(manager.albumArt != nil && manager.hasArtworkGradient)
        assert(manager.sourceApp?.displayName == "Apple Music")
        assert(artUpdates == 1 && gradientUpdates == 1 && sourceUpdates == 1)
        let firstImage = manager.albumArt!
        for time in 2...101 {
            state.currentTime = Double(time)
            state.lastUpdated = Date(timeIntervalSince1970: Double(time))
            controller.subject.send(state)
        }
        pump()
        assert(manager.albumArt === firstImage && manager.playbackState.currentTime == 101)
        assert(artUpdates == 1 && gradientUpdates == 1 && sourceUpdates == 1,
               "progress updates must reuse artwork, gradient and source metadata")
        let previousStateUpdates = stateUpdates
        for _ in 0..<10 { controller.subject.send(state) }
        pump()
        assert(stateUpdates == previousStateUpdates, "identical states must not refresh views")

        state.artworkData = Data([UInt8](png))
        state.isPlaying = false
        controller.subject.send(state)
        pump()
        assert(manager.albumArt === firstImage && artUpdates == 1,
               "equal artwork bytes and transport changes must retain the same image")

        bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 0, y: 0)
        state.artworkData = bitmap.representation(using: .png, properties: [:])!
        controller.subject.send(state)
        waitFor("new artwork must replace the old image", { artUpdates == 2 })
        assert(manager.albumArt !== firstImage && artUpdates == 2 && gradientUpdates == 2)
        state.artworkData = nil
        controller.subject.send(state)
        pump()
        assert(manager.albumArt == nil && !manager.hasArtworkGradient)
        assert(artUpdates == 3 && gradientUpdates == 3)

        state.bundleIdentifier = "com.apple.finder"
        controller.subject.send(state)
        pump()
        assert(manager.sourceApp?.bundleIdentifier == "com.apple.finder" && sourceUpdates == 2)
        assert(artUpdates == 3 && gradientUpdates == 3)
        state.bundleIdentifier = nil
        controller.subject.send(state)
        pump()
        assert(manager.sourceApp == nil && sourceUpdates == 3)
        state.artworkData = Data("invalid image".utf8)
        controller.subject.send(state)
        let invalidCompletion = ArtworkProbe.shared.counts.completed + 1
        waitFor("invalid image worker must finish", { ArtworkProbe.shared.counts.completed >= invalidCompletion })
        pump()
        assert(manager.albumArt == nil && !manager.hasArtworkGradient)

        let probe = ArtworkProbe.shared
        let largeRed = syntheticPNG(size: 4096, red: 1, blue: 0)
        let blue = syntheticPNG(size: 512, red: 0, blue: 1)
        probe.hold(largeRed)
        state.artworkData = largeRed
        controller.subject.send(state)
        waitFor("old artwork must reach the worker gate", { probe.counts.waiting })
        let oldCompletion = probe.counts.completed
        state.artworkData = blue
        controller.subject.send(state)
        waitFor("newer artwork must finish while the old result is held", {
            probe.counts.completed == oldCompletion + 1 && manager.hasArtworkGradient
        })
        let blueImage = manager.albumArt!
        let blueGradient = manager.artworkGradient
        probe.release.signal()
        waitFor("cancelled old worker must finish", { probe.counts.completed == oldCompletion + 2 })
        pump()
        assert(manager.albumArt === blueImage && manager.artworkGradient == blueGradient,
               "an older prepared result must never overwrite the newer song")

        probe.hold(largeRed)
        state.artworkData = largeRed
        controller.subject.send(state)
        waitFor("clear test must hold an in-flight result", { probe.counts.waiting })
        let clearCompletion = probe.counts.completed
        state.artworkData = nil
        controller.subject.send(state)
        waitFor("clearing art must immediately reset it", { manager.albumArt == nil })
        probe.release.signal()
        waitFor("cancelled clear worker must finish", { probe.counts.completed == clearCompletion + 1 })
        pump()
        assert(manager.albumArt == nil && !manager.hasArtworkGradient,
               "a completed older result must not resurrect cleared artwork")

        probe.hold(largeRed)
        state.artworkData = largeRed
        controller.subject.send(state)
        waitFor("same-art test must hold an in-flight result", { probe.counts.waiting })
        let inFlightCount = probe.counts.started
        for time in 102...201 {
            state.currentTime = Double(time)
            controller.subject.send(state)
        }
        pump()
        assert(probe.counts.started == inFlightCount,
               "progress updates must not restart an unfinished artwork task")
        probe.release.signal()
        waitFor("retained in-flight artwork must finish", { manager.albumArt != nil })
        assert(manager.playbackState.currentTime == 201)
        let decoded = manager.albumArt!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        assert(decoded.width <= 256 && decoded.height <= 256,
               "published artwork must already be downsampled and decoded")

        // Isolated synthetic timing evidence; this is not a whole-app frame-rate measurement.
        state.artworkData = blue
        controller.subject.send(state)
        waitFor("timing setup must finish", { manager.albumArt!.size.width == 256 && probe.counts.started > inFlightCount })
        pump()
        let priorImage = manager.albumArt
        let timingStart = Date()
        var maxMainTurn = 0.0
        state.artworkData = largeRed
        controller.subject.send(state)
        while manager.albumArt === priorImage && Date().timeIntervalSince(timingStart) < 5 {
            let turnStart = Date()
            pump(0.001)
            maxMainTurn = max(maxMainTurn, Date().timeIntervalSince(turnStart))
        }
        precondition(manager.albumArt !== priorImage, "timed artwork must publish")
        print(String(format: "Synthetic 4096px PNG: worker %.2f ms, largest main run-loop turn %.2f ms, published 256px thumbnail",
                     probe.counts.duration * 1000, maxMainTurn * 1000))
        print("PASS: off-main decode/gradient, latest-result wins, clear cancellation, in-flight/progress reuse, duplicates, replacement and source metadata")
        withExtendedLifetime(subscriptions) {}
    }
}
'''

with tempfile.TemporaryDirectory(prefix='lumora-music-check-') as directory:
    directory = Path(directory)
    test = directory / 'Check.swift'
    test.write_text(check.replace('assert(', 'precondition('))
    manager = directory / 'MusicManager.swift'
    source = (repo / 'Lumora/Services/Music/MusicManager.swift').read_text()
    marker = 'let result = Self.prepareArtwork(data)'
    assert source.count(marker) == 1
    manager.write_text(source.replace(marker, '''let started = ArtworkProbe.shared.begin()
            let result = Self.prepareArtwork(data)
            ArtworkProbe.shared.finish(data, since: started)'''))
    executable = directory / 'check'
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-sdk', str(sdk),
        '-target', 'arm64-apple-macosx15.6', '-O', '-whole-module-optimization',
        '-default-isolation', 'MainActor',
        '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault',
        '-enable-upcoming-feature', 'InferIsolatedConformances',
        '-enable-upcoming-feature', 'MemberImportVisibility',
        '-enable-upcoming-feature', 'DisableOutwardActorInference',
        '-enable-upcoming-feature', 'InferSendableFromCaptures',
        '-enable-upcoming-feature', 'GlobalActorIsolatedTypesUsability',
        str(repo / 'Lumora/Models/PlaybackState.swift'),
        str(repo / 'Lumora/Services/Music/MediaControllerProtocol.swift'),
        str(manager), str(test),
        '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
