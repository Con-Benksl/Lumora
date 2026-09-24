#!/usr/bin/env python3
"""Exercise the production glow layers offscreen; no Lumora launch or desktop input.

Checks the native rotation contract, attachment/removal, stable phase, reduced
motion, and SwiftUI teardown. The read-only OS motion value is injected into a
temporary copy; the production body, representable and CALayers are unchanged.
These checks do not measure on-screen frame rate.
"""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
sdk = os.environ.get("LUMORA_SWIFT_SDK", "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
if not Path(sdk).exists():
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
source = (repo / "Lumora/UI/Views/NotchView.swift").read_text()
a = source.index("private struct VibeSurroundGlow: View {")
b = source.index("/// Audio frames stay in these leaves", a)
glow = source[a:b]
motion_property = r"@Environment(\.accessibilityReduceMotion) private var reduceMotion"
assert glow.count(motion_property) == 1
glow = glow.replace(motion_property, "var reduceMotion = false")

check = r'''
import AppKit
import SwiftUI

@main struct Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: .borderless, backing: .buffered, defer: false)
        let native = VibeGradientView(frame: CGRect(x: 0, y: 0, width: 360, height: 140))
        func gradient(_ view: VibeGradientView) -> CAGradientLayer {
            view.layer!.sublayers!.first as! CAGradientLayer
        }
        func rotation(_ view: VibeGradientView) -> CABasicAnimation? {
            gradient(view).animation(forKey: "vibeRotation") as? CABasicAnimation
        }
        func samePhase(_ first: CABasicAnimation, _ second: CABasicAnimation) -> Bool {
            let cycles = (first.beginTime - second.beginTime) / 7.2
            return abs(cycles - cycles.rounded()) < 0.001
        }
        func flush() {
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        native.setAnimating(true)
        precondition(rotation(native) == nil, "detached glow must not animate")
        window.contentView = native
        flush()
        let first = rotation(native)!
        precondition(first.duration == 7.2 && first.repeatCount == .infinity)
        precondition((first.fromValue as! NSNumber).doubleValue == 0)
        precondition(abs((first.toValue as! NSNumber).doubleValue + 2 * .pi) < 0.0001)
        precondition(first.timingFunction == CAMediaTimingFunction(name: .linear))
        // The unshown AppKit host exposes real presentation-layer samples.
        // Several intermediate angles must advance within the old 286 ms tick.
        func angle() -> CGFloat {
            let transform = gradient(native).presentation()!.transform
            return atan2(transform.m12, transform.m11)
        }
        var previousAngle = angle()
        var previousTime = CACurrentMediaTime()
        for _ in 0..<4 {
            flush()
            let currentAngle = angle()
            let now = CACurrentMediaTime()
            let delta = atan2(sin(previousAngle - currentAngle), cos(previousAngle - currentAngle))
            let expected = 2 * .pi * (now - previousTime) / 7.2
            precondition(delta > 0 && abs(delta - expected) < max(0.008, expected * 0.25),
                "native presentation rotation is not interpolating continuously")
            previousAngle = currentAngle
            previousTime = now
        }
        precondition(gradient(native).bounds.width >= hypot(native.bounds.width, native.bounds.height))
        native.setAnimating(true)
        native.frame.size = CGSize(width: 420, height: 160)
        native.needsLayout = true
        flush()
        precondition(rotation(native)!.beginTime == first.beginTime, "updates must not restart rotation")
        precondition(gradient(native).bounds.width >= hypot(native.bounds.width, native.bounds.height))
        native.removeFromSuperview()
        precondition(rotation(native) == nil, "detached glow retained an animation")
        window.contentView = native
        flush()
        let resumed = rotation(native)!
        precondition(samePhase(resumed, first),
            "remount must keep the shared cycle phase")
        native.setAnimating(false)
        precondition(rotation(native) == nil, "reduced motion must stop rotation")
        native.setAnimating(true)
        precondition(rotation(native) != nil)
        VibeSurroundGradient.dismantleNSView(native, coordinator: ())
        precondition(rotation(native) == nil, "dismantle must stop rotation")

        func content(_ reduced: Bool) -> AnyView {
            AnyView(VibeSurroundGlow(topCornerRadius: 6, bottomCornerRadius: 12, reduceMotion: reduced)
                .frame(width: 240, height: 32))
        }
        func find(_ root: NSView) -> [VibeGradientView] {
            (root as? VibeGradientView).map { [$0] } ?? root.subviews.flatMap(find)
        }
        let host = NSHostingView(rootView: content(false))
        window.contentView = host
        flush()
        let halos = find(host)
        precondition(halos.count == 2, "expected inner and outer native gradients")
        precondition(halos.allSatisfy { rotation($0) != nil })
        precondition(samePhase(rotation(halos[0])!, rotation(halos[1])!),
            "inner and outer gradients must stay aligned")
        host.rootView = content(true)
        flush()
        precondition(find(host).allSatisfy { rotation($0) == nil }, "SwiftUI reduced motion did not stop rotation")
        host.rootView = content(false)
        flush()
        precondition(find(host).allSatisfy { rotation($0) != nil })
        host.rootView = AnyView(EmptyView())
        flush()
        precondition(halos.allSatisfy { rotation($0) == nil }, "removed glow is still animating")
        print("PASS: native glow interpolation, shared phase, sizing, reduced motion and teardown")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="lumora-vibe-glow-") as temporary:
    directory = Path(temporary)
    main = directory / "Check.swift"
    main.write_text(check + glow)
    executable = directory / "check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-sdk", sdk,
        "-o", str(executable), str(main),
    ], check=True)
    subprocess.run([str(executable)], check=True)
