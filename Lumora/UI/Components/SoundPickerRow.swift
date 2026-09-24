//
//  SoundPickerRow.swift
//  Lumora
//
//  Notification sound selection picker for settings menu
//

import SwiftUI

struct SoundPickerRow: View {
    @ObservedObject var soundSelector: SoundSelector
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    var onToggle: ((Bool, CGFloat) -> Void)? = nil
    @State private var selectedSound: NotificationSound = AppSettings.notificationSound

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { soundSelector.isPickerExpanded },
            set: { soundSelector.isPickerExpanded = $0 }
        )
    }

    /// Compile-time layout for this picker's expanded content.
    /// The inner ScrollView caps visible rows at 6 (`min(count, 6) *
    /// `settingsSubPickerRowHeight`), and subRows have no sublabel
    /// (font-metric-derived: 12pt label + 20pt vertical padding
    /// = 34.13pt). We use the capped height because the picker never
    /// grows beyond 6 rows — extra rows scroll inside the picker's
    /// own ScrollView.
    static var pickerLayout: PickerLayout {
        let visibleRows = min(NotificationSound.allCases.count, 6)
        return PickerLayout(
            rowCount: visibleRows,
            rowHeight: settingsSubPickerRowHeight
        )
    }

    var body: some View {
        ExpandableSettingsRow(
            icon: "speaker.wave.2",
            label: String(localized: "Notification Sound"),
            trailingText: selectedSound.displayName,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: isFocused,
            isExpanded: isExpandedBinding,
            targetHeight: Self.pickerLayout.expandedHeight,
            onToggle: onToggle
        ) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(NotificationSound.allCases, id: \.self) { sound in
                        SettingsSubPickerRow(
                            label: sound.displayName,
                            isSelected: selectedSound == sound,
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor
                        ) {
                            NotificationSoundPlayer.play(sound)
                            selectedSound = sound
                            AppSettings.notificationSound = sound
                        }
                    }
                }
            }
            // Inner ScrollView height must equal the picker's expected
            // content height (from `Self.pickerLayout.expandedHeight` minus
            // the 4pt topPadding baked into PickerLayout). The previous
            // hardcoded `* 32` left a ~27pt empty row at the bottom of the
            // expanded picker. The ScrollView still caps at 6 visible
            // rows — extra sounds scroll inside this ScrollView.
            .frame(maxHeight: Self.pickerLayout.expandedHeight - 4)
        }
        .onAppear {
            selectedSound = AppSettings.notificationSound
        }
    }
}
