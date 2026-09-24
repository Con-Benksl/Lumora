//
//  ProcessingSpinner.swift
//  Lumora
//
//  Animated symbol spinner for processing state
//

import SwiftUI

enum SessionLoadingStyle {
    static let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    static let frameDuration: TimeInterval = 0.15

    static func tint(for provider: SessionProvider) -> Color {
        switch provider {
        case .claude:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:
            return Color(red: 0.35, green: 0.62, blue: 0.96)
        case .opencode:
            return Color(red: 0.40, green: 0.80, blue: 0.40)
        case .cursor:
            return Color(red: 0.70, green: 0.70, blue: 0.68)
        }
    }
}

struct ProcessingSpinner: View {
    let color: Color
    let provider: SessionProvider?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(color: Color = SessionLoadingStyle.tint(for: .claude)) {
        self.color = color
        self.provider = nil
    }

    init(provider: SessionProvider) {
        self.color = SessionLoadingStyle.tint(for: provider)
        self.provider = provider
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: provider == .codex ? 1.0 / 30.0 : SessionLoadingStyle.frameDuration,
            paused: reduceMotion
        )) { timeline in
            let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            if provider == .codex {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.18), lineWidth: 1.6)

                    Circle()
                        .trim(from: 0.12, to: 0.72)
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(elapsed.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360))
                }
                .frame(width: 16, height: 16)
            } else {
                let phase = reduceMotion ? 2 : Int(elapsed / SessionLoadingStyle.frameDuration)
                Text(SessionLoadingStyle.symbols[phase % SessionLoadingStyle.symbols.count])
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 16, alignment: .center)
            }
        }
    }
}

struct SessionLoadingRow: View {
    let provider: SessionProvider
    var turnId: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let baseTexts = [String(localized: "Processing"), String(localized: "Working")]

    private var tint: Color {
        SessionLoadingStyle.tint(for: provider)
    }

    private var baseText: String {
        let index = abs(turnId.hashValue) % baseTexts.count
        return baseTexts[index]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.4, paused: reduceMotion)) { timeline in
            let dotCount = reduceMotion ? 3 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.4) % 3 + 1
            HStack(alignment: .center, spacing: 6) {
                ProcessingSpinner(provider: provider)
                    .frame(width: 6)

                Text(baseText + String(repeating: ".", count: dotCount))
                    .font(.system(size: 13))
                    .foregroundColor(tint)

                Spacer()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(baseText))
    }
}

#if DEBUG
#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
#endif
