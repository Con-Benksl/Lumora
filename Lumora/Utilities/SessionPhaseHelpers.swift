//
//  SessionPhaseHelpers.swift
//  Lumora
//
//  Helper functions for session phase display
//

import SwiftUI

struct SessionPhaseHelpers {
    /// Get color for session phase
    static func phaseColor(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval, .waitingForTerminalApproval:
            return TerminalColors.amber
        case .waitingForInput:
            return TerminalColors.green
        case .processing:
            return TerminalColors.cyan
        case .compacting:
            return TerminalColors.magenta
        case .idle, .ended:
            return TerminalColors.dim
        }
    }

    /// Get description for session phase
    static func phaseDescription(for phase: SessionPhase) -> String {
        switch phase {
        case .waitingForApproval(let ctx):
            return String(localized: "Waiting for approval: \(ctx.toolName)")
        case .waitingForTerminalApproval(let ctx):
            return String(localized: "Approval needed in terminal: \(ctx.toolName)")
        case .waitingForInput:
            return String(localized: "Ready for input")
        case .processing:
            return String(localized: "Processing...")
        case .compacting:
            return String(localized: "Compacting context...")
        case .idle:
            return String(localized: "Idle")
        case .ended:
            return String(localized: "Ended")
        }
    }

    /// Format time ago string
    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return String(localized: "Just now") }
        if seconds < 60 { return String(localized: "\(seconds)s") }
        if seconds < 3600 { return String(localized: "\(seconds / 60)m") }
        if seconds < 86400 { return String(localized: "\(seconds / 3600)h") }
        return String(localized: "\(seconds / 86400)d")
    }
}
