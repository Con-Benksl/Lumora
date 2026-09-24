import CoreGraphics
import Foundation

struct MenuBarAvoidanceState {
    private(set) var isYielding = false
    private var clearSince: Date?
    private let settleInterval: TimeInterval = 0.3

    mutating func begin() {
        isYielding = true
        clearSince = nil
    }

    mutating func stop() {
        isYielding = false
        clearSince = nil
    }

    mutating func update(items: [CGRect]?, protectedRect: CGRect?, now: Date = Date()) -> Bool {
        if Self.hasCollision(items: items, protectedRect: protectedRect) {
            clearSince = nil
            isYielding = true
        } else if isYielding {
            if let clearSince, now.timeIntervalSince(clearSince) >= settleInterval {
                isYielding = false
            } else if clearSince == nil {
                clearSince = now
            }
        }
        return isYielding
    }

    static func hasCollision(items: [CGRect]?, protectedRect: CGRect?) -> Bool {
        guard let items, let protectedRect else { return true }
        let protectedArea = protectedRect.insetBy(dx: -4, dy: 0)
        return items.contains { $0.intersects(protectedArea) }
    }
}
