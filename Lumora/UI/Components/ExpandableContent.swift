//
//  ExpandableContent.swift
//  Lumora
//
//  Animated expand/collapse container. The content is always in the
//  view tree. Its visible height is driven by the parent — `targetHeight`
//  is the picker's expanded height, computed at compile time via
//  `PickerLayout.expandedHeight` (see SettingsPageLayout.swift). No
//  GeometryReader, no preference key, no measurement feedback — those
//  caused the 9-fix scrollbar flicker saga. With deterministic
//  targetHeight, panel height and ScrollView contentSize stay
//  mathematically equal at every frame.
//
//  Two visual layers animate together when `isExpanded` toggles:
//  - Frame: `0` ↔ `targetHeight`, animated with `.settingsExpand`
//    (0.2s easeInOut) to match the panel's `notchSize` animation curve.
//  - Opacity: `0` ↔ `1`, animated with `.easeInOut(duration: 0.2)` —
//    same curve, so the fade lands exactly when the height finishes
//    growing.
//
//  `targetHeight` is supplied by the parent view (a `PickerLayout`
//  computed from the picker's known row count). When `targetHeight`
//  is 0 (no layout data yet, e.g. during the first render before the
//  parent computes it), the picker collapses to 0 — same behavior as
//  the previous GeometryReader-cached path.
//

import SwiftUI

struct ExpandableContent<Content: View>: View {
    let isExpanded: Bool
    /// Height the picker should occupy when expanded. Supplied by the
    /// parent via `PickerLayout.expandedHeight` — no measurement here.
    let targetHeight: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .opacity(isExpanded ? 1 : 0)
            .frame(height: isExpanded ? targetHeight : 0, alignment: .top)
            .clipped()
            .animation(reduceMotion ? nil : .settingsExpand, value: isExpanded)
    }
}
