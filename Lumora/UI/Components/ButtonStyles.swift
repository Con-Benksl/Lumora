import SwiftUI

/// Avoid the native dark overlay on custom rows while keeping Button's
/// keyboard and accessibility behavior. Press feedback changes only opacity,
/// so clicking never moves the target or starts another layout animation.
struct NoPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled && configuration.isPressed ? 0.76 : 1)
            .animation(
                reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
