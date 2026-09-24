//
//  PerformanceSettingsView.swift
//  Lumora
//
//  Sub-page consolidating performance-related settings.
//

import SwiftUI
import Combine

struct PerformanceSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color

    @AppStorage(AppSettings.performanceMonitorEnabledKey) private var performanceMonitorEnabled = true
    @AppStorage(AppSettings.musicAbovePerformanceKey) private var musicAbovePerformance = false
    @AppStorage(AppSettings.performanceVisibleSectionsKey) private var visibleSectionsRaw: String = "cpu,memory,battery,network"

    @State private var didAppear = false
    // (baseHeightRecorded removed 2026-07-02 — see PickerLayout /
    //  PageLayout helpers in SettingsPageLayout.swift; height is
    //  compile-time via `performanceSettingsContentHeight` getter.)

    /// Compile-time layout for the Visible Metrics picker: 4 subRows
    /// (CPU/Memory/Battery/Network) using `SettingsSubToggleRow`
    /// (26.13pt tall — font-metric-derived from 12pt label + 6/6
    /// vertical padding).
    static var metricsPickerLayout: PickerLayout {
        PickerLayout(rowCount: 4, rowHeight: settingsSubToggleRowHeight)
    }

    /// Compile-time layout for the entire performance settings page:
    /// 4 rows (Back, Monitor, Music-above, Visible Metrics) + 2
    /// dividers. All rows are `MenuRow` / `MenuToggleRow`
    /// (font-metric `menuRowHeight` = 35.31pt).
    static var pageLayout: PageLayout {
        PageLayout(rowCount: 4, dividerCount: 2)
    }

    /// Total content height = base (no picker expanded) + picker
    /// contribution (when expanded). Compile-time, no GeometryReader.
    private var performanceSettingsContentHeight: CGFloat {
        Self.pageLayout.dynamicHeight(expandedPickerHeights: [
            viewModel.performanceSettingsMetricsExpanded
                ? Self.metricsPickerLayout.expandedHeight
                : 0
        ])
    }

    private var visibleSet: Set<String> {
        Set(visibleSectionsRaw.split(separator: ",").map { String($0) })
    }

    private var visibleCount: Int {
        PerformanceSection.detailAll.filter { visibleSet.contains($0.rawValue) }.count
    }

    private func isSectionVisible(_ section: PerformanceSection) -> Bool {
        visibleSet.contains(section.rawValue)
    }

    /// Minimum 2 sections must remain visible.
    private func canDisable(_ section: PerformanceSection) -> Bool {
        !(isSectionVisible(section) && visibleCount <= 2)
    }

    private func toggleSection(_ section: PerformanceSection) {
        guard canDisable(section) else { return }
        var current = visibleSet
        if current.contains(section.rawValue) {
            current.remove(section.rawValue)
        } else {
            current.insert(section.rawValue)
        }
        let ordered = PerformanceSection.detailAll.filter { current.contains($0.rawValue) }
        visibleSectionsRaw = ordered.map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                MenuRow(
                    icon: "chevron.left",
                    label: String(localized: "Back"),
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 0
                ) {
                    viewModel.navigateBack()
                }

                Divider().background(separatorColor).padding(.vertical, 4)

                MenuToggleRow(
                    icon: "gauge.with.dots.needle.33percent",
                    label: String(localized: "Performance Monitor"),
                    isOn: performanceMonitorEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 1
                ) {
                    performanceMonitorEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "arrow.up.arrow.down",
                    label: String(localized: "Show Performance Below Music"),
                    isOn: musicAbovePerformance,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 2
                ) {
                    musicAbovePerformance.toggle()
                }

                Divider().background(separatorColor).padding(.vertical, 4)

                ExpandableSettingsRow(
                    icon: "rectangle.grid.1x2",
                    label: String(localized: "Visible Metrics"),
                    trailingText: "\(visibleCount)/4",
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 3,
                    isExpanded: $viewModel.performanceSettingsMetricsExpanded,
                    targetHeight: Self.metricsPickerLayout.expandedHeight,
                    onToggle: { _, _ in
                        // Re-derive compile-time height after the
                        // picker expanded state flipped. PageLayout +
                        // PickerLayout are bit-for-bit equal to the
                        // ScrollView's contentSize, so panel.maxHeight
                        // = contentSize at every frame.
                        viewModel.performanceSettingsContentHeight = performanceSettingsContentHeight
                    }
                ) {
                    ForEach(Array(PerformanceSection.detailAll.enumerated()), id: \.element) { index, section in
                        let focusedIndex = 4 + index
                        SettingsSubToggleRow(
                            label: section.title,
                            isOn: isSectionVisible(section),
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor,
                            isFocused: viewModel.settingsFocusedIndex == focusedIndex,
                            locked: !canDisable(section)
                        ) {
                            toggleSection(section)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // (GeometryReader / onPreferenceChange removed 2026-07-02 —
        //  font-metric-derived row heights in SettingsPageLayout.swift
        //  make PageLayout.staticHeight bit-for-bit equal to ScrollView
        //  contentSize; no measurement feedback needed.)
        .onAppear {
            didAppear = true
            // Match the convention used by SoundPickerRow / ScreenPickerRow /
            // ChatView section toggles / Claude dir picker: every picker
            // defaults to closed and resets when the page is re-entered.
            // The collapsed state still shows useful info ("2/4") so users
            // can scan visibility without expanding.
            viewModel.performanceSettingsMetricsExpanded = false
            // Push initial compile-time height (matches ScrollView
            // contentSize bit-for-bit, so no GeometryReader needed).
            viewModel.performanceSettingsContentHeight = performanceSettingsContentHeight
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            switch viewModel.settingsFocusedIndex {
            case 0: viewModel.navigateBack()
            case 1: performanceMonitorEnabled.toggle()
            case 2: musicAbovePerformance.toggle()
            case 3:
                // Animate both panel height and picker frame in the
                // same withAnimation block. Re-derive compile-time
                // height from PageLayout + PickerLayout — no
                // measurement, no incremental +=.
                let newExpanded = !viewModel.performanceSettingsMetricsExpanded
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.performanceSettingsMetricsExpanded = newExpanded
                    viewModel.performanceSettingsContentHeight = performanceSettingsContentHeight
                    if !newExpanded {
                        viewModel.settingsFocusedIndex = 3
                    }
                }
            case 4: toggleSection(.cpu)
            case 5: toggleSection(.memory)
            case 6: toggleSection(.battery)
            case 7: toggleSection(.network)
            default: break
            }
        }
    }
}

// (PerformanceSettingsContentHeightKey PreferenceKey removed 2026-07-02
//  — GeometryReader feedback loop eliminated by switching to font-metric
//  row heights in SettingsPageLayout.swift. PageLayout.dynamicHeight
//  matches ScrollView.contentSize at every frame.)
