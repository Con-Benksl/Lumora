import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class NowPlayingController: MediaControllerProtocol {
    private enum PlaybackCommand: UInt32 {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private struct PendingOptimisticToggle {
        let until: Date
        let expectedIsPlaying: Bool
    }

    private let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState())
    private let logger = Logger(subsystem: "com.conbenksl.lumora", category: "NowPlaying")
    private let optimisticToggleProtectionWindow: TimeInterval = 0.8
    private let optimisticElapsedTolerance: TimeInterval = 1.0

    private var pollingTask: Task<Void, Never>?
    private var initialRefreshTask: Task<Void, Never>?
    private var pendingOptimisticToggle: PendingOptimisticToggle?
    private var isRefreshInFlight = false

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    init() {
        startStreamingUpdates()
        scheduleInitialRefreshes()
    }

    deinit {
        initialRefreshTask?.cancel()
        pollingTask?.cancel()
    }
}

extension NowPlayingController {
    func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSnapshot(context: "refresh")
        }
    }

    func restartStreaming() {
        cleanupStream()
        startStreamingUpdates()
        scheduleInitialRefreshes()
    }

    func togglePlayPause(displayedTime: TimeInterval?) {
        sendCommand(.togglePlayPause, displayedTime: displayedTime)
    }

    func nextTrack() {
        sendCommand(.nextTrack)
    }

    func previousTrack() {
        sendCommand(.previousTrack)
    }

    func openSourceApp() {
        let configuration = NSWorkspace.OpenConfiguration()

        if let bundleIdentifier = subject.value.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
            return
        }

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Music.app"),
            configuration: configuration
        ) { _, _ in }
    }

    // Seeking remains disabled because MediaRemote's set-elapsed-time command
    // reports failure on current macOS releases.
}

private extension NowPlayingController {
    func startStreamingUpdates() {
        cleanupStream()
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshSnapshot(context: "poll")
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
            }
        }
    }

    private func scheduleInitialRefreshes() {
        initialRefreshTask?.cancel()
        initialRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.refreshSnapshot(context: "initial-refresh")

            for delay in [0.75, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard self.needsInitialRefreshRetry else { return }
                await self.refreshSnapshot(context: "initial-refresh-retry")
            }
        }
    }

    private var needsInitialRefreshRetry: Bool {
        let state = subject.value
        return !state.hasDisplayableContent || state.artworkData == nil
    }

    private func cleanupStream() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @discardableResult
    private func refreshSnapshot(context: String) async -> Bool {
        guard !isRefreshInFlight else { return false }
        isRefreshInFlight = true
        defer { isRefreshInFlight = false }

        let result: Result<MediaRemoteSnapshot, MediaRemoteClientError> = await withCheckedContinuation { continuation in
            MediaRemoteClient.shared.fetchNowPlayingInfo { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success(let snapshot):
            applySnapshot(snapshot)
            return true
        case .failure(let error):
            logger.error("Now-playing refresh failed during \(context, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func sendCommand(_ command: PlaybackCommand, displayedTime: TimeInterval? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.debug(
                "sendCommand command=\(command.rawValue) displayedTime=\(String(describing: displayedTime), privacy: .public) currentTime=\(self.subject.value.currentTime, privacy: .public) isPlaying=\(self.subject.value.isPlaying, privacy: .public) lastUpdated=\(self.subject.value.lastUpdated.ISO8601Format(), privacy: .public)"
            )
            self.applyOptimisticState(for: command, displayedTime: displayedTime)
            guard MediaRemoteClient.shared.send(command: command.rawValue) else {
                self.logger.error("MediaRemote command \(command.rawValue) could not be sent")
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
            self.refresh()
        }
    }

    private func applyOptimisticState(for command: PlaybackCommand, displayedTime: TimeInterval?) {
        guard command == .togglePlayPause else { return }

        let current = subject.value
        let now = Date()
        let optimisticCurrentTime = displayedTime.map {
            clampedElapsedTime($0, duration: current.duration)
        } ?? projectedElapsedTime(for: current, at: now)

        var optimistic = current
        optimistic.currentTime = optimisticCurrentTime
        optimistic.lastUpdated = now
        optimistic.isPlaying.toggle()
        pendingOptimisticToggle = PendingOptimisticToggle(
            until: now.addingTimeInterval(optimisticToggleProtectionWindow),
            expectedIsPlaying: optimistic.isPlaying
        )
        logger.debug(
            "optimisticToggle displayedTime=\(String(describing: displayedTime), privacy: .public) optimisticCurrentTime=\(optimisticCurrentTime, privacy: .public) previousCurrentTime=\(current.currentTime, privacy: .public) previousIsPlaying=\(current.isPlaying, privacy: .public) optimisticIsPlaying=\(optimistic.isPlaying, privacy: .public) protectUntil=\(self.pendingOptimisticToggle?.until.ISO8601Format() ?? "nil", privacy: .public)"
        )
        subject.send(optimistic)
    }

    private func clampedElapsedTime(_ elapsedTime: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, elapsedTime) }
        return min(max(0, elapsedTime), duration)
    }

    private func applySnapshot(_ snapshot: MediaRemoteSnapshot) {
        if snapshot.title == nil && snapshot.artist == nil && !snapshot.isPlaying {
            if subject.value.hasDisplayableContent {
                subject.send(PlaybackState())
            }
            return
        }

        let payload = NowPlayingPayload(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration,
            elapsedTime: snapshot.elapsedTime,
            timestamp: snapshot.timestamp,
            playbackRate: snapshot.playbackRate,
            artworkData: snapshot.artworkData?.base64EncodedString(),
            playing: snapshot.isPlaying,
            bundleIdentifier: snapshot.bundleIdentifier
        )

        let previousState = subject.value
        let state = makePlaybackState(payload: payload, previous: previousState)
        let reconciledState = reconcileSnapshotIfNeeded(
            snapshot: payload,
            incoming: state,
            previous: previousState
        )
        logger.debug(
            "applySnapshot playing=\(snapshot.isPlaying, privacy: .public) elapsedTime=\(String(describing: snapshot.elapsedTime), privacy: .public) playbackRate=\(String(describing: snapshot.playbackRate), privacy: .public) timestamp=\(String(describing: snapshot.timestamp), privacy: .public) -> currentTime=\(reconciledState.currentTime, privacy: .public) isPlaying=\(reconciledState.isPlaying, privacy: .public) lastUpdated=\(reconciledState.lastUpdated.ISO8601Format(), privacy: .public)"
        )
        subject.send(reconciledState)
    }

    private func reconcileSnapshotIfNeeded(
        snapshot: NowPlayingPayload,
        incoming: PlaybackState,
        previous: PlaybackState
    ) -> PlaybackState {
        guard let pending = pendingOptimisticToggle else { return incoming }

        let now = Date()
        guard now < pending.until else {
            pendingOptimisticToggle = nil
            return incoming
        }

        let previousProjectedTime = projectedElapsedTime(for: previous, at: now)
        let incomingProjectedTime = projectedElapsedTime(for: incoming, at: now)
        let hasExplicitTransportToggle = snapshot.playing != nil
        let hasStaleTransportState = hasExplicitTransportToggle
            && incoming.isPlaying != pending.expectedIsPlaying
        let hasLargeElapsedJump = abs(incomingProjectedTime - previousProjectedTime) > optimisticElapsedTolerance

        guard hasStaleTransportState || hasLargeElapsedJump else {
            if hasExplicitTransportToggle && incoming.isPlaying == pending.expectedIsPlaying {
                pendingOptimisticToggle = nil
            }
            return incoming
        }

        var reconciled = incoming
        reconciled.isPlaying = pending.expectedIsPlaying
        reconciled.currentTime = previousProjectedTime
        reconciled.lastUpdated = now
        logger.debug(
            "reconcileSnapshot previousProjected=\(previousProjectedTime, privacy: .public) incomingProjected=\(incomingProjectedTime, privacy: .public) reconciledCurrentTime=\(reconciled.currentTime, privacy: .public) incomingIsPlaying=\(incoming.isPlaying, privacy: .public) expectedIsPlaying=\(pending.expectedIsPlaying, privacy: .public)"
        )
        return reconciled
    }

    private func projectedElapsedTime(for state: PlaybackState, at date: Date) -> TimeInterval {
        guard state.isPlaying else {
            return clampedElapsedTime(state.currentTime, duration: state.duration)
        }

        let delta = max(0, date.timeIntervalSince(state.lastUpdated))
        return clampedElapsedTime(state.currentTime + (delta * state.playbackRate), duration: state.duration)
    }

    private func makePlaybackState(
        payload: NowPlayingPayload,
        previous: PlaybackState
    ) -> PlaybackState {
        let bundleIdentifier = payload.bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let title = resolvedString(payload.title)
        let artist = resolvedString(payload.artist)
        let album = resolvedString(payload.album)

        return PlaybackState(
            bundleIdentifier: bundleIdentifier,
            isPlaying: payload.playing ?? false,
            title: title,
            artist: artist,
            album: album,
            currentTime: resolvedDouble(payload.elapsedTime),
            duration: resolvedDouble(payload.duration),
            playbackRate: resolvedDouble(payload.playbackRate),
            lastUpdated: payload.timestamp ?? Date(),
            artworkData: resolvedArtworkData(
                payload.artworkData,
                previous: previous,
                bundleIdentifier: bundleIdentifier,
                title: title,
                artist: artist,
                album: album
            )
        )
    }

    private func resolvedString(_ value: String?) -> String {
        value ?? ""
    }

    private func resolvedDouble(_ value: Double?) -> Double {
        value ?? 0
    }

    private func resolvedArtworkData(
        _ value: String?,
        previous: PlaybackState,
        bundleIdentifier: String?,
        title: String,
        artist: String,
        album: String
    ) -> Data? {
        if let value, !value.isEmpty {
            return Data(base64Encoded: value)
        }
        guard let previousArtwork = previous.artworkData else { return nil }
        guard isSameNowPlayingItem(
            previous: previous,
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: artist,
            album: album
        ) else {
            return nil
        }
        return previousArtwork
    }

    private func isSameNowPlayingItem(
        previous: PlaybackState,
        bundleIdentifier: String?,
        title: String,
        artist: String,
        album: String
    ) -> Bool {
        let previousTitle = normalizedPlaybackText(previous.title)
        let incomingTitle = normalizedPlaybackText(title)
        guard !incomingTitle.isEmpty, incomingTitle == previousTitle else {
            return false
        }

        return playbackFieldMatches(incoming: artist, previous: previous.artist)
            && playbackFieldMatches(incoming: album, previous: previous.album)
            && playbackFieldMatches(incoming: bundleIdentifier, previous: previous.bundleIdentifier)
    }

    private func playbackFieldMatches(incoming: String?, previous: String?) -> Bool {
        let incomingText = normalizedPlaybackText(incoming)
        let previousText = normalizedPlaybackText(previous)
        return incomingText.isEmpty || previousText.isEmpty || incomingText == previousText
    }

    private func normalizedPlaybackText(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct NowPlayingPayload {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let timestamp: Date?
    let playbackRate: Double?
    let artworkData: String?
    let playing: Bool?
    let bundleIdentifier: String?
}
