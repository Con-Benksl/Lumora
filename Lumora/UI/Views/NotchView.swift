//
//  NotchView.swift
//  Lumora
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

struct NotchView: View {
    private struct ExpandedNotchTheme {
        let backgroundGradient: LinearGradient
        let overlayColor: Color
        let primaryText: Color
        let secondaryText: Color
        let separator: Color
        let headerIcon: Color
    }

    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = SessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @StateObject private var musicManager = MusicManager()
    // Only the small audio views observe spectrum updates; a beat must not
    // invalidate the panel, settings, and chat tree during an open animation.
    private let musicAudioAnalyzer = MusicAudioAnalyzer.shared
    @State private var performanceMonitor = PerformanceMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var previousCompletionNotificationMarkers: [String: Date] = [:]
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    // Provider currently at the FRONT of the multi-agent icon stack.
    // Other working agents are stacked behind in priority order. A
    // 2s timer rotates this cursor so each agent gets a turn at the
    // front (with the spinner color tracking along).
    @State private var carouselFront: SessionProvider?
    // IMPORTANT: Timer.publish must be a stable instance — recreating
    // it on every body evaluation (which fires often via @ObservedObject
    // updates) resets the 2-second countdown, so the timer NEVER fires.
    // deepseek-v4-flash review caught this: body re-runs ~every state
    // change, each one starts a fresh publisher → no rotation.
    private let carouselTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()
    @AppStorage(AppSettings.notchAppearanceStyleKey) private var notchAppearanceStyleRaw = NotchAppearanceStyle.adaptiveArtwork.rawValue
    @AppStorage(AppSettings.musicEdgeGlowEnabledKey) private var musicEdgeGlowEnabled = false
    @AppStorage(AppSettings.musicAudioReactiveGlowEnabledKey) private var musicAudioReactiveGlowEnabled = false
    @AppStorage(AppSettings.vibeGlowEnabledKey) private var vibeGlowEnabled = false
    @AppStorage(AppSettings.performanceMonitorEnabledKey) private var performanceMonitorEnabled = true

    @Namespace private var activityNamespace

    /// Whether any tracked session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    private var activeProcessingActivityType: NotchActivityType? {
        activeProcessingProviders.first.map { provider in
            switch provider {
            case .claude: return .claude
            case .codex: return .codex
            case .opencode: return .opencode
            case .cursor: return .cursor
            }
        }
    }

    /// All currently processing providers, in priority order
    /// (claude > codex > opencode > cursor). Empty if no agent is
    /// processing. Used by the closed-state header to render a
    /// stacked "peek" of icons — see `headerRow` below.
    private var activeProcessingProviders: [SessionProvider] {
        var providers: [SessionProvider] = []
        if sessionMonitor.instances.contains(where: { $0.provider == .claude && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.claude)
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .codex && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.codex)
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .opencode && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.opencode)
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .cursor && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.cursor)
        }
        return providers
    }

    /// Display order for the icon stack. Always at most 2 elements:
    /// the current `carouselFront` and the front's "next" provider in
    /// the priority-ordered active list. When the providers list
    /// changes, the current front (if still active) is preserved so
    /// the carousel doesn't jump. With 0 active providers the stack
    /// is empty; with 1 active the stack is just that one icon (no
    /// peek). With 2+ active the second icon is the front's successor
    /// in the rotation, so it changes as the front cycles.
    private var displayOrder: [SessionProvider] {
        let active = activeProcessingProviders
        guard !active.isEmpty else { return [] }
        if let front = carouselFront, let frontIndex = active.firstIndex(of: front) {
            // N=1: no peek — avoid rendering a faded ghost of the same icon.
            guard active.count > 1 else { return [front] }
            let nextIndex = (frontIndex + 1) % active.count
            return [front, active[nextIndex]]
        }
        return Array(active.prefix(2))
    }
    private var activePendingPermissionActivityType: NotchActivityType? {
        if sessionMonitor.instances.contains(where: { $0.provider == .claude && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .claude
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .codex && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .codex
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .opencode && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .opencode
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .cursor && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .cursor
        }
        return nil
    }

    /// Whether any tracked session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval }
    }

    /// Whether any tracked session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return waitingForInputTimestamps.values.contains { enteredAt in
            now.timeIntervalSince(enteredAt) < displayDuration
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        let baseExpansion = 2 * max(0, closedNotchSize.height - 12) + 20

        if showMusicActivity {
            return baseExpansion
        }

        guard !suppressesHeaderAgentActivity else {
            return 0
        }

        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0

        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude, .codex, .opencode, .cursor:
                return baseExpansion + permissionIndicatorWidth
            case .none:
                break
            }
        }

        if hasPendingPermission {
            return baseExpansion + permissionIndicatorWidth
        }

        if hasWaitingForInput {
            return baseExpansion
        }

        return 0
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return viewModel.geometry.closedPanelSize(expansionWidth: expansionWidth)
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.animatedTopCornerRadius
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.animatedBottomCornerRadius
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                panel
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onAppear {
            viewModel.closedNotchExpansionWidth = expansionWidth
            sessionMonitor.startMonitoring()
            performanceMonitor.setActive(performanceMonitorEnabled)
            syncInstancesPageLayoutState()
            handleProcessingChange()
            syncMusicAudioAnalysis()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .task(id: shouldShowPanel) {
            if shouldShowPanel {
                isVisible = true
            } else {
                // A reopen cancels this task, so an old close cannot hide a
                // newer transition halfway through.
                do {
                    try await Task.sleep(for: .seconds(reduceMotion ? 0 : PanelMotion.closeSpring.settlingDuration))
                } catch { return }
                guard !Task.isCancelled else { return }
                isVisible = false
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            syncInstancesPageLayoutState()
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: sessionMonitor.completionNotification) { _, notification in
            guard let notification else { return }
            handleCompletionNotification(notification)
        }
        .onChange(of: musicManager.playbackState) { _, _ in
            syncInstancesPageLayoutState()
            handleProcessingChange()
            syncMusicAudioAnalysis()
        }
        .onChange(of: musicEdgeGlowEnabled) { _, _ in
            syncMusicAudioAnalysis()
        }
        .onChange(of: musicAudioReactiveGlowEnabled) { _, _ in
            syncMusicAudioAnalysis()
        }
        .onChange(of: performanceMonitorEnabled) { _, isEnabled in
            performanceMonitor.setActive(isEnabled)
            syncInstancesPageLayoutState()
        }
        .onChange(of: expansionWidth) { _, newValue in
            viewModel.closedNotchExpansionWidth = newValue
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        guard activityCoordinator.expandingActivity.show else { return false }

        switch activityCoordinator.expandingActivity.type {
        case .claude, .codex, .opencode, .cursor:
            return true
        case .none:
            return false
        }
    }

    private var activeWaitingForInputActivityType: NotchActivityType? {
        let activeIds = Set(waitingForInputTimestamps.keys)
        guard let session = sessionMonitor.instances.first(where: { activeIds.contains($0.stableId) }) else {
            return nil
        }
        return activityType(for: session.provider)
    }

    private var closedActivityType: NotchActivityType {
        if isProcessing || hasPendingPermission {
            return activityCoordinator.expandingActivity.type
        }
        if hasWaitingForInput {
            return activeWaitingForInputActivityType ?? activityCoordinator.expandingActivity.type
        }
        return activityCoordinator.expandingActivity.type
    }

    private var closedActivityProvider: SessionProvider {
        switch closedActivityType {
        case .codex:
            return .codex
        case .opencode:
            return .opencode
        case .cursor:
            return .cursor
        case .claude, .none:
            return .claude
        }
    }

    private var closedActivityTint: Color {
        SessionLoadingStyle.tint(for: closedActivityProvider)
    }

    private func activityType(for provider: SessionProvider) -> NotchActivityType {
        switch provider {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .opencode:
            return .opencode
        case .cursor:
            return .cursor
        }
    }

    private var showMusicActivity: Bool {
        musicManager.isVisible && (usesClosedVibeMode || (!hasPendingPermission && !isAnyProcessing))
    }

    private var showCompactMusicActivity: Bool {
        viewModel.status != .opened && showMusicActivity
    }

    private var hasArtworkThemeSource: Bool {
        musicManager.albumArt != nil && musicManager.hasArtworkGradient
    }

    private var notchAppearanceStyle: NotchAppearanceStyle {
        if reduceTransparency { return .pureBlack }
        return (NotchAppearanceStyle(rawValue: notchAppearanceStyleRaw) ?? .adaptiveArtwork)
            .resolvedForCurrentSystem
    }

    private var isArtworkAdaptiveBackgroundVisible: Bool {
        viewModel.status == .opened
            && musicManager.isVisible
            && notchAppearanceStyle == .adaptiveArtwork
            && hasArtworkThemeSource
    }

    private var expandedNotchTheme: ExpandedNotchTheme {
        let colors = musicManager.artworkGradient.map(Color.init(nsColor:))
        let useDarkForeground = perceivedBrightness(for: musicManager.artworkGradient) > 0.72

        return ExpandedNotchTheme(
            backgroundGradient: LinearGradient(
                colors: colors + [colors.last ?? .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            overlayColor: useDarkForeground ? Color.black.opacity(0.18) : Color.black.opacity(0.36),
            primaryText: useDarkForeground ? Color.black.opacity(0.82) : Color.white.opacity(0.96),
            secondaryText: useDarkForeground ? Color.black.opacity(0.58) : Color.white.opacity(0.62),
            separator: useDarkForeground ? Color.black.opacity(0.12) : Color.white.opacity(0.10),
            headerIcon: useDarkForeground ? Color.black.opacity(0.56) : Color.white.opacity(0.5)
        )
    }

    private var expandedPrimaryTextColor: Color {
        isArtworkAdaptiveBackgroundVisible ? expandedNotchTheme.primaryText : .white
    }

    private var expandedSecondaryTextColor: Color {
        isArtworkAdaptiveBackgroundVisible ? expandedNotchTheme.secondaryText : .white.opacity(0.6)
    }

    private var expandedSeparatorColor: Color {
        isArtworkAdaptiveBackgroundVisible ? expandedNotchTheme.separator : .white.opacity(0.08)
    }

    private var expandedHeaderIconColor: Color {
        isArtworkAdaptiveBackgroundVisible ? expandedNotchTheme.headerIcon : .white.opacity(0.6)
    }

    private var isExpandedLiquidGlassVisible: Bool {
        viewModel.status == .opened && notchAppearanceStyle == .liquidGlass
    }

    private var notchShadowColor: Color {
        if isExpandedLiquidGlassVisible {
            return Color.black.opacity(0.24)
        }

        return (viewModel.status == .opened || isHovering) ? .black.opacity(0.3) : .clear
    }

    private var notchShadowRadius: CGFloat {
        viewModel.status == .opened ? 14 : 6
    }

    @ViewBuilder
    private var notchBackground: some View {
        let shape = NotchShape(
            topCornerRadius: viewModel.animatedTopCornerRadius,
            bottomCornerRadius: viewModel.animatedBottomCornerRadius
        )

        switch notchAppearanceStyle {
        case .liquidGlass where viewModel.status == .opened:
            liquidGlassBackground(in: shape)
        case .liquidGlass:
            pureBlackBackground(in: shape)
        case .adaptiveArtwork:
            if isArtworkAdaptiveBackgroundVisible {
                adaptiveArtworkBackground(in: shape)
            } else {
                pureBlackBackground(in: shape)
            }
        case .pureBlack:
            pureBlackBackground(in: shape)
        }
    }

    @ViewBuilder
    private func adaptiveArtworkBackground(in shape: NotchShape) -> some View {
        shape
            .fill(expandedNotchTheme.backgroundGradient)
            .overlay(
                RadialGradient(
                    colors: [
                        expandedNotchTheme.primaryText.opacity(0.08),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 12,
                    endRadius: notchSize.width * 0.9
                )
            )
            .overlay(expandedNotchTheme.overlayColor)
            .clipShape(shape)
    }

    @ViewBuilder
    private func liquidGlassBackground(in shape: NotchShape) -> some View {
        if #available(macOS 26.0, *) {
#if compiler(>=6.2)
            shape
                .fill(Color.white.opacity(0.03))
                .glassEffect(.regular, in: shape)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.035)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(shape)
                )
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 1))
#else
            legacyGlassBackground(in: shape)
#endif
        } else {
            pureBlackBackground(in: shape)
        }
    }

    private func legacyGlassBackground(in shape: NotchShape) -> some View {
        shape
            .fill(.regularMaterial)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.12),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            )
            .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    private func pureBlackBackground(in shape: NotchShape) -> some View {
        shape.fill(Color.black)
    }

    private var showHeaderAgentActivity: Bool {
        !suppressesHeaderAgentActivity && (isProcessing || hasPendingPermission || hasWaitingForInput)
    }

    private var usesClosedVibeMode: Bool {
        vibeGlowEnabled && viewModel.status != .opened && isAnyProcessing
    }

    private var suppressesHeaderAgentActivity: Bool {
        vibeGlowEnabled
    }

    private var vibeGlowVisible: Bool {
        vibeGlowEnabled && viewModel.status == .closed && isAnyProcessing
    }

    @ViewBuilder
    private var edgeGlowOverlay: some View {
        if vibeGlowVisible {
            if reduceMotion {
                NotchBottomEdge(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .stroke(Color.white.opacity(0.45), lineWidth: 2)
            } else {
                VibeSurroundGlow(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
            }
        } else if viewModel.status == .closed && musicEdgeGlowEnabled {
            NotchMusicGlow(
                analyzer: musicAudioAnalyzer,
                isAudioReactiveEnabled: musicAudioReactiveGlowEnabled,
                isPlaying: musicManager.playbackState.isPlaying,
                colors: musicManager.edgeGlowGradient.map(Color.init(nsColor:)),
                topCornerRadius: topCornerRadius,
                bottomCornerRadius: bottomCornerRadius
            )
        }
    }

    @ViewBuilder
    private var panel: some View {
        notchLayout
            .frame(
                width: viewModel.status == .opened ? viewModel.openedSize.width - 24 : closedContentWidth,
                alignment: .top
            )
            .padding(.horizontal, 12)
            .padding(.bottom, viewModel.status == .opened ? 12 : 0)
            .frame(width: notchSize.width, height: notchSize.height, alignment: .top)
            .background(PanelPresentationReader(presentation: viewModel.panelPresentation).allowsHitTesting(false))
            .background {
                notchBackground
            }
            .clipShape(NotchShape(
                topCornerRadius: viewModel.animatedTopCornerRadius,
                bottomCornerRadius: viewModel.animatedBottomCornerRadius
            ))
            .overlay(edgeGlowOverlay)
            .shadow(
                color: notchShadowColor,
                radius: notchShadowRadius
            )
            .panelAnimationContract(
                inputs: PanelAnimationInputs(
                    notchSize: notchSize,
                    status: viewModel.status,
                    expandingActivity: activityCoordinator.expandingActivity,
                    hasPendingPermission: hasPendingPermission,
                    hasWaitingForInput: hasWaitingForInput,
                    showMusicActivity: showMusicActivity,
                    vibeGlowEnabled: vibeGlowEnabled,
                    notchAppearanceStyleRaw: notchAppearanceStyleRaw,
                    artworkData: musicManager.playbackState.artworkData,
                    isBouncing: isBouncing
                ),
                reduceMotion: reduceMotion
            )
            .onChange(of: notchSize) { oldValue, newValue in
                // DIAGNOSTIC: log panel size changes to correlate with scrollbar visibility
                DebugLog.shared.write("[notch-size] h:\(String(format: "%.1f", oldValue.height))→\(String(format: "%.1f", newValue.height)) w:\(String(format: "%.1f", oldValue.width))→\(String(format: "%.1f", newValue.width)) status=\(viewModel.status)")
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
            .onTapGesture {
                if viewModel.status != .opened {
                    // Don't re-open if we just closed due to clicking the notch area.
                    // The NSEvent monitor fires first and already handled the close;
                    // without this guard the SwiftUI gesture would immediately re-open.
                    if let closedAt = viewModel.closedByTapAt,
                       Date().timeIntervalSince(closedAt) < 0.2 {
                        return
                    }
                    handleNotchTap()
                }
            }
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: settingsPageHeaderHeight(for: viewModel.geometry))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: viewModel.openedSize.width - 24)
                    .transition(.panelContent(reduceMotion: reduceMotion))
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        if showCompactMusicActivity {
            NotchCompactMusic(
                musicManager: musicManager,
                analyzer: musicAudioAnalyzer,
                isAudioReactiveEnabled: musicAudioReactiveGlowEnabled
            )
                .frame(width: closedContentWidth, height: closedNotchSize.height, alignment: .leading)
                .frame(height: closedNotchSize.height)
                .transition(.panelCompact(reduceMotion: reduceMotion))
        } else {
            HStack(spacing: 0) {
                if showHeaderAgentActivity {
                    HStack(spacing: 4) {
                        // Stacked "peek" of working-agent icons. When
                        // multiple agents are processing simultaneously,
                        // the `displayOrder` starts at `carouselFront`
                        // and rotates every 2s. The leftmost icon (front)
                        // is fully visible; the others peek out ~8.3pt to
                        // the right, sorted by priority from the front.
                        // Each icon's own pulse/movement animation is
                        // independent (Claude legs, Codex glow,
                        // OpenCode squish, Cursor highlight pulse), so
                        // the stack reads as alive on its own.
                        if !activeProcessingProviders.isEmpty {
                            ZStack(alignment: .leading) {
                                ForEach(Array(displayOrder.enumerated()), id: \.element) { index, provider in
                                    let isFront = index == 0
                                    AgentIcon(
                                        provider: provider,
                                        size: 16,
                                        color: SessionLoadingStyle.tint(for: provider),
                                        animate: !reduceMotion
                                    )
                                    .padding(1)
                                    .scaleEffect(isFront ? 1.0 : 0.85, anchor: .center)
                                    .opacity(isFront ? 1.0 : 0.55)
                                    .offset(x: CGFloat(index) * 11)
                                    .zIndex(Double(displayOrder.count - index))
                                    .animation(.smooth(duration: 0.5), value: isFront)
                                }
                            }
                            .matchedGeometryEffect(id: "agent-icons", in: activityNamespace, isSource: showHeaderAgentActivity)
                            .animation(.smooth(duration: 0.5), value: displayOrder)
                            // Rotate the carousel front every 2s so each
                            // working agent gets a turn. No-op when ≤1
                            // provider (the stack is just one icon).
                            .onReceive(carouselTimer) { _ in
                                // TODO(progress): carousel front/back
                                // animation tuning still in progress.
                                // Debug logs kept until rotation is
                                // confirmed working as intended across
                                // all multi-agent scenarios. See PROGRESS.md.
                                guard !reduceMotion else { return }
                                let active = activeProcessingProviders
                                let activeDesc = active.map { $0.rawValue }.joined(separator: ",")
                                DebugLog.shared.write("[carousel] tick active=[\(activeDesc)] count=\(active.count) currentFront=\(carouselFront?.rawValue ?? "nil")")
                                guard active.count > 1 else { return }
                                // If the cached front is no longer in the
                                // active set (provider stopped since last
                                // tick), reset to the current first active
                                // provider. Without this, the carousel
                                // gets stuck because firstIndex(of:) returns
                                // nil forever and we never advance.
                                let resolvedFront: SessionProvider = {
                                    if let f = carouselFront, active.contains(f) {
                                        return f
                                    }
                                    let reset = active.first!
                                    DebugLog.shared.write("[carousel] stale front reset → \(reset.rawValue)")
                                    carouselFront = reset
                                    return reset
                                }()
                                guard let i = active.firstIndex(of: resolvedFront) else {
                                    DebugLog.shared.write("[carousel] resolvedFront missing post-reset, skip")
                                    return
                                }
                                let next = active[(i + 1) % active.count]
                                DebugLog.shared.write("[carousel] rotating front \(resolvedFront.rawValue) → \(next.rawValue)")
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    carouselFront = next
                                }
                            }
                        }

                        if hasPendingPermission {
                            PermissionIndicatorIcon(size: 16, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                                .padding(1)
                                .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showHeaderAgentActivity)
                        }
                    }
                }

                if viewModel.status == .opened {
                    openedHeaderContent
                        .transition(.panelContent(reduceMotion: reduceMotion))
                } else if !showHeaderAgentActivity {
                    Spacer()
                } else {
                    Spacer()
                        .background(Color.black)
                }

                if showHeaderAgentActivity {
                    if isProcessing || hasPendingPermission {
                        // Spinner follows the carousel front. When the
                        // front rotates, the spinner color animates to
                        // the next provider's tint (via .animation(value:)
                        // on the color binding).
                        //
                        // Ignore carouselFront if it points to a provider
                        // that's no longer processing (e.g. OpenCode
                        // stopped but carouselFront still cached .opencode) —
                        // fall through to activeProcessingProviders.first
                        // so the spinner switches to Claude immediately.
                        let active = activeProcessingProviders
                        let spinnerProvider: SessionProvider = {
                            if let f = carouselFront, active.contains(f) { return f }
                            return active.first ?? closedActivityProvider
                        }()
                        let spinnerColor = SessionLoadingStyle.tint(for: spinnerProvider)
                        ProcessingSpinner(color: spinnerColor)
                            .animation(.easeInOut(duration: 0.5), value: spinnerProvider)
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showHeaderAgentActivity)
                    } else if hasWaitingForInput {
                        ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                            .padding(1)
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showHeaderAgentActivity)
                    }
                }
            }
            .padding(.horizontal, 7)
            .frame(width: viewModel.status == .opened ? nil : closedContentWidth)
            .frame(height: closedNotchSize.height)
            .opacity(isBouncing && !reduceMotion ? 0.65 : 1)
            // The whole header exits when compact music replaces it.
            .transition(.panelContent(reduceMotion: reduceMotion))
        }
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            Spacer()

            // Menu toggle
            Button {
                withAnimation(reduceMotion ? nil : .settingsExpand) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(expandedHeaderIconColor)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(NoPressButtonStyle())
            .accessibilityLabel(viewModel.contentType == .menu ? String(localized: "Back") : String(localized: "Settings…"))
            .help(viewModel.contentType == .menu ? String(localized: "Back") : String(localized: "Settings…"))
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                SessionListView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel,
                    musicManager: musicManager,
                    performanceMonitor: performanceMonitor,
                    isPerformanceMonitorEnabled: performanceMonitorEnabled
                )
            case .menu:
                NotchMenuView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .shortcuts:
                ShortcutSettingsView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .agents:
                AgentSettingsView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .performanceSettings:
                PerformanceSettingsView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .betaFeatures:
                BetaFeaturesSettingsView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor,
                    musicBundleIdentifier: musicManager.playbackState.bundleIdentifier
                )
            case .performance(let section):
                PerformanceDetailView(
                    viewModel: viewModel,
                    monitor: performanceMonitor,
                    section: section,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor
                )
            }
        }
        .frame(width: viewModel.openedSize.width - 24) // Keep text at its reading width while the shell closes.
        // Removed .id() - was causing view recreation and performance issues
    }

    private func perceivedBrightness(for colors: [NSColor]) -> CGFloat {
        let samples = colors.compactMap { $0.usingColorSpace(.deviceRGB) }
        guard !samples.isEmpty else { return 0 }

        let total = samples.reduce(CGFloat.zero) { partialResult, color in
            partialResult + ((color.redComponent * 0.299) + (color.greenComponent * 0.587) + (color.blueComponent * 0.114))
        }

        return total / CGFloat(samples.count)
    }

    private func syncInstancesPageLayoutState() {
        let sessionCount = sessionMonitor.instances.count
        let hasSessions = sessionCount > 0
        let showsMusic = musicManager.isVisible

        if viewModel.instancesPageHasSessions != hasSessions { viewModel.instancesPageHasSessions = hasSessions }
        if viewModel.instancesPageSessionCount != sessionCount { viewModel.instancesPageSessionCount = sessionCount }
        if viewModel.instancesPageShowsPerformance != performanceMonitorEnabled { viewModel.instancesPageShowsPerformance = performanceMonitorEnabled }
        if viewModel.instancesPageShowsMusic != showsMusic { viewModel.instancesPageShowsMusic = showsMusic }
    }

    private func syncMusicAudioAnalysis() {
        let playback = musicManager.playbackState
        musicAudioAnalyzer.sync(
            enabled: MusicGlowPresentationMode.shouldAnalyzeAudio(
                isEdgeGlowEnabled: musicEdgeGlowEnabled,
                isAudioReactiveEnabled: musicAudioReactiveGlowEnabled,
                isPlaying: playback.isPlaying
            ),
            isPlaying: playback.isPlaying,
            bundleIdentifier: playback.bundleIdentifier,
            title: playback.title,
            artist: playback.artist
        )
    }

    // MARK: - Event Handlers

    private var shouldShowPanel: Bool {
        !viewModel.hasPhysicalNotch || viewModel.status != .closed ||
        isAnyProcessing || hasPendingPermission || hasWaitingForInput ||
        showMusicActivity || activityCoordinator.expandingActivity.show
    }

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            let activityType = activePendingPermissionActivityType ?? activeProcessingActivityType ?? .claude
            activityCoordinator.showActivity(type: activityType)
        } else {
            activityCoordinator.hideActivity()
        }
    }

    private func handleNotchTap() {
        viewModel.handleNotchTap()
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover || viewModel.openReason == .keyboard {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            break // The cancellable visibility task waits for the shell to settle.
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        let displayDuration: TimeInterval = 30
        let now = Date()

        // Get sessions that are now waiting for user action.
        let waitingForInputSessions = instances.filter {
            $0.phase == .waitingForInput || $0.phase.isWaitingForTerminalApproval
        }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Track synthetic completion notifications for providers that keep a
        // short completed marker in the active session list.
        let completionMarkerSessions = instances.filter {
            $0.provider == .cursor && $0.completionNotificationAt != nil
        }
        var currentCompletionMarkers: [String: Date] = [:]
        var newCompletionSessions: [SessionState] = []

        for session in completionMarkerSessions {
            guard let completionAt = session.completionNotificationAt else { continue }
            currentCompletionMarkers[session.stableId] = completionAt

            if previousCompletionNotificationMarkers[session.stableId] != completionAt {
                waitingForInputTimestamps[session.stableId] = completionAt
                newCompletionSessions.append(session)
            }
        }

        let activeTimestampIds = currentIds.union(currentCompletionMarkers.keys)

        // Clean up timestamps for sessions that no longer qualify or have expired.
        for (stableId, enteredAt) in waitingForInputTimestamps {
            let isStillActive = activeTimestampIds.contains(stableId)
            let isStillVisible = now.timeIntervalSince(enteredAt) < displayDuration
            if !isStillActive || !isStillVisible {
                waitingForInputTimestamps.removeValue(forKey: stableId)
            }
        }

        let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }
        let newlyCompletedSessions = newlyWaitingSessions + newCompletionSessions

        // Bounce the notch when a session newly enters waiting-for-input or emits a completion marker.
        if !newlyCompletedSessions.isEmpty {
            let debugContext = newlyCompletedSessions
                .map { "provider=\($0.provider.rawValue) session=\($0.sessionId)" }
                .joined(separator: ",")
            playNotificationSoundIfNeeded(forPids: newlyCompletedSessions.map(\.pid), debugContext: debugContext)
            triggerNotificationBounce()

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
        previousCompletionNotificationMarkers = currentCompletionMarkers
    }

    private func handleCompletionNotification(_ notification: SessionCompletionNotification) {
        let debugContext = "provider=\(notification.provider.rawValue) session=\(notification.sessionId)"
        DebugLog.shared.write("[notch-notification] completionReceived \(debugContext)")
        playNotificationSoundIfNeeded(forPids: [notification.pid], debugContext: debugContext)
        triggerNotificationBounce()
    }

    private func playNotificationSoundIfNeeded(forPids pids: [Int?], debugContext: String) {
        guard AppSettings.notificationSound.soundName != nil else { return }

        Task {
            let shouldPlaySound = await shouldPlayNotificationSound(forPids: pids)
            if shouldPlaySound {
                await MainActor.run {
                    NotificationSoundPlayer.play(AppSettings.notificationSound)
                }
                DebugLog.shared.write("[notch-notification] soundPlayed \(debugContext)")
            } else {
                DebugLog.shared.write("[notch-notification] soundSkippedFocused \(debugContext)")
            }
        }
    }

    private func triggerNotificationBounce() {
        DispatchQueue.main.async {
            isBouncing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isBouncing = false
            }
        }
    }

    /// Returns true if ANY notifying session is not actively focused.
    private func shouldPlayNotificationSound(forPids pids: [Int?]) async -> Bool {
        for pid in pids {
            guard let pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}

private struct VibeSurroundGlow: View {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Give the native gradient enough room for the stroke and its soft halo.
    private let glowPadding: CGFloat = 48

    var body: some View {
        ZStack {
            VibeSurroundGradient(isAnimating: !reduceMotion)
                .mask {
                    VibeSurroundEdge(
                        topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius,
                        outwardOffset: 10
                    )
                    .stroke(.white, style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round))
                    .padding(glowPadding)
                }
                .blur(radius: 16)
                .opacity(0.34)

            VibeSurroundGradient(isAnimating: !reduceMotion)
                .mask {
                    VibeSurroundEdge(
                        topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius,
                        outwardOffset: 3
                    )
                    .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .padding(glowPadding)
                }
                .blur(radius: 4)
                .opacity(0.56)
        }
        .padding(-glowPadding)
        .allowsHitTesting(false)
    }
}

private struct VibeSurroundGradient: NSViewRepresentable {
    let isAnimating: Bool

    func makeNSView(context: Context) -> VibeGradientView {
        let view = VibeGradientView()
        view.setAnimating(isAnimating)
        return view
    }

    func updateNSView(_ view: VibeGradientView, context: Context) {
        view.setAnimating(isAnimating)
    }

    static func dismantleNSView(_ view: VibeGradientView, coordinator: ()) {
        view.setAnimating(false)
    }
}

/// Core Animation interpolates the rotation without a SwiftUI frame timer.
private final class VibeGradientView: NSView {
    private let gradient = CAGradientLayer()
    private var isAnimating = false
    private let cycleDuration: TimeInterval = 7.2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            NSColor(srgbRed: 0.24, green: 0.82, blue: 1.00, alpha: 1).cgColor,
            NSColor(srgbRed: 0.76, green: 0.42, blue: 1.00, alpha: 1).cgColor,
            NSColor(srgbRed: 1.00, green: 0.42, blue: 0.68, alpha: 1).cgColor,
            NSColor(srgbRed: 0.34, green: 0.92, blue: 0.74, alpha: 1).cgColor,
            NSColor(srgbRed: 0.24, green: 0.82, blue: 1.00, alpha: 1).cgColor,
        ]
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // A rotating square must cover the rectangular host at every angle.
        let side = hypot(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRotation()
    }

    func setAnimating(_ value: Bool) {
        isAnimating = value
        updateRotation()
    }

    private func updateRotation() {
        guard isAnimating, window != nil else {
            gradient.removeAnimation(forKey: "vibeRotation")
            return
        }
        guard gradient.animation(forKey: "vibeRotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -2 * Double.pi
        rotation.duration = cycleDuration
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        // Both halos and remounted views share one clock, so neither restarts
        // at an arbitrary angle after opening the panel or a settings update.
        let now = CACurrentMediaTime()
        rotation.beginTime = gradient.convertTime(
            now - now.truncatingRemainder(dividingBy: cycleDuration), from: nil
        )
        gradient.add(rotation, forKey: "vibeRotation")
    }
}

private struct VibeSurroundEdge: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var outwardOffset: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topY = rect.minY
        let bottomY = rect.maxY + outwardOffset
        let leftX = rect.minX + topCornerRadius - outwardOffset
        let rightX = rect.maxX - topCornerRadius + outwardOffset

        path.move(to: CGPoint(x: rect.maxX + outwardOffset, y: topY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: topY + topCornerRadius),
            control: CGPoint(x: rightX, y: topY)
        )
        path.addLine(to: CGPoint(x: rightX, y: bottomY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rightX - bottomCornerRadius, y: bottomY),
            control: CGPoint(x: rightX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: leftX + bottomCornerRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: leftX, y: bottomY - bottomCornerRadius),
            control: CGPoint(x: leftX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: leftX, y: topY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX - outwardOffset, y: topY),
            control: CGPoint(x: leftX, y: topY)
        )

        return path
    }
}

/// Audio frames stay in these leaves instead of invalidating the whole panel.
private struct NotchCompactMusic: View {
    let musicManager: MusicManager
    @ObservedObject var analyzer: MusicAudioAnalyzer
    let isAudioReactiveEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CompactMusicActivityView(
            musicManager: musicManager,
            realSpectrumLevels: isAudioReactiveEnabled && !reduceMotion
                ? analyzer.realSpectrumLevels : nil
        )
    }
}

private struct NotchMusicGlow: View {
    @ObservedObject var analyzer: MusicAudioAnalyzer
    let isAudioReactiveEnabled: Bool
    let isPlaying: Bool
    let colors: [Color]
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathingOpacity = 0.75

    private var mode: MusicGlowPresentationMode {
        MusicGlowPresentationMode.resolve(
            isEdgeGlowEnabled: true,
            isAudioReactiveEnabled: isAudioReactiveEnabled,
            isPlaying: isPlaying,
            isAnalyzerRunning: analyzer.isRunning,
            canPresentGlow: true
        )
    }

    private var opacity: Double {
        if reduceMotion { return 0.45 }
        if mode == .simulated { return breathingOpacity * 0.75 }
        let intensity = Double(min(max(analyzer.glowIntensity, 0), 1))
        let visible = min(max((intensity - 0.12) / 0.88, 0), 1)
        return visible * visible * (3 - 2 * visible) * 0.95
    }

    var body: some View {
        if mode != .hidden {
            NotchBottomEdge(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                .stroke(
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .blur(radius: 6)
                .opacity(opacity)
                .task(id: mode == .simulated && !reduceMotion) {
                    guard mode == .simulated && !reduceMotion else { return }
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 1.5)) { breathingOpacity = 0.15 }
                        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                        withAnimation(.easeInOut(duration: 1.5)) { breathingOpacity = 1 }
                        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                    }
                }
        }
    }
}
