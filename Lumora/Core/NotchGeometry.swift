//
//  NotchGeometry.swift
//  Lumora
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - deviceNotchRect.width / 2,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        return CGRect(
            x: screenRect.midX - size.width / 2,
            y: screenRect.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Matches the closed panel frame, including the activity indicators.
    func closedPanelSize(expansionWidth: CGFloat = 0) -> CGSize {
        CGSize(
            width: deviceNotchRect.width + expansionWidth + 24,
            height: max(24, deviceNotchRect.height)
        )
    }

    func closedScreenRect(expansionWidth: CGFloat = 0) -> CGRect {
        openedScreenRect(for: closedPanelSize(expansionWidth: expansionWidth))
    }

    /// A small margin makes the closed notch easier to acquire with the pointer.
    func isPointInNotch(_ point: CGPoint, expansionWidth: CGFloat = 0) -> Bool {
        closedScreenRect(expansionWidth: expansionWidth)
            .insetBy(dx: -5, dy: -5).contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !openedScreenRect(for: size).contains(point)
    }
}
