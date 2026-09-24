import XCTest
@testable import Lumora

final class NotchAppearanceStyleTests: XCTestCase {
    func testLiquidGlassAvailabilityFollowsCurrentMacOSVersion() {
        if #available(macOS 26.0, *) {
            XCTAssertTrue(NotchAppearanceStyle.availableCases.contains(.liquidGlass))
            XCTAssertEqual(NotchAppearanceStyle.liquidGlass.resolvedForCurrentSystem, .liquidGlass)
        } else {
            XCTAssertFalse(NotchAppearanceStyle.availableCases.contains(.liquidGlass))
            XCTAssertEqual(NotchAppearanceStyle.liquidGlass.resolvedForCurrentSystem, .adaptiveArtwork)
        }
    }
}
