#!/usr/bin/env python3
"""Exercise the production AppKit observer and its SwiftUI overlay offscreen."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
if not sdk.exists():
    sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())

check = r'''
import AppKit
import SwiftUI

@main struct Check {
    @MainActor static func pump(_ duration: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let unrelated = NSScrollView(frame: window.contentView!.bounds)
        unrelated.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 999))
        unrelated.scrollerStyle = .legacy
        window.contentView!.addSubview(unrelated)

        let target = NSScrollView(frame: window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        target.documentView = document
        window.contentView!.addSubview(target)
        var samples: [CGFloat] = []
        let observer = ScrollViewOverlayObserver(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        observer.onMeasure = { samples.append($0) }
        observer.isActive = true
        document.addSubview(observer)
        pump()
        assert(samples.count >= 2 && samples.allSatisfy { $0 == 600 })
        assert(target.scrollerStyle == .overlay && unrelated.scrollerStyle == .legacy)
        document.setFrameSize(NSSize(width: 400, height: 700))
        pump()
        assert(samples.last == 700)

        observer.isActive = false
        let stoppedCount = samples.count
        pump()
        assert(samples.count == stoppedCount, "hidden menus must stop sampling")
        observer.isActive = true
        pump()
        assert(samples.count > stoppedCount)
        observer.removeFromSuperview()
        let detachedCount = samples.count
        pump()
        assert(samples.count == detachedCount, "detached probes must stop sampling")
        unrelated.documentView!.addSubview(observer)
        pump()
        assert(samples.last == 999, "remounts must select their new enclosing scroll view")
        ScrollViewOverlayStyle.dismantleNSView(observer, coordinator: ())
        let dismantledCount = samples.count
        pump()
        assert(samples.count == dismantledCount && observer.onMeasure == nil)

        // Use the same placement as NotchMenuView. No ordered window or UI input.
        var swiftUISamples: [CGFloat] = []
        let host = NSHostingView(rootView:
            ScrollView(.vertical) {
                VStack { Text("Settings") }.frame(height: 500)
                    .overlay(alignment: .topLeading) {
                        ScrollViewOverlayStyle(isActive: true) { swiftUISamples.append($0) }
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.5)
        assert(swiftUISamples.count >= 2 && swiftUISamples.allSatisfy { $0 >= 500 },
               "SwiftUI must instantiate the probe inside the actual scroll content")
        window.contentView = NSView()
        let removedCount = swiftUISamples.count
        pump()
        assert(swiftUISamples.count == removedCount)
        print("PASS: targeted scroll measurement, unchanged settling samples, hide/remount/teardown, SwiftUI overlay")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='lumora-scroll-check-') as directory:
    directory = Path(directory)
    test = directory / 'Check.swift'
    test.write_text(check)
    executable = directory / 'check'
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-sdk', str(sdk),
        str(repo / 'Lumora/UI/Components/ScrollViewOverlayStyle.swift'), str(test),
        '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
