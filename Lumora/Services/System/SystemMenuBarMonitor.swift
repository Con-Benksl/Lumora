import AppKit
import ApplicationServices

/// macOS 27 combines status items in MenuBarAgent. Read geometry through AX,
/// without screen capture, rearranging other apps, or polling the render thread.
@MainActor
final class SystemMenuBarMonitor {
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(_ receive: @escaping @MainActor ([CGRect]?, Bool) -> Void) {
        stop()
        let token = generation
        func refresh() {
            guard task == nil else { return }
            let trusted = AXIsProcessTrusted()
            guard trusted, let pid = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.MenuBarAgent"
            ).first?.processIdentifier else {
                receive(nil, trusted)
                return
            }
            // AX and CG use a top-left origin anchored to the primary display,
            // even when the selected Lumora screen is above or left of it.
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            task = Task { [weak self] in
                let worker = Task.detached(priority: .utility) {
                    Self.readFrames(pid: pid)
                }
                let frames = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.generation == token else { return }
                self.task = nil
                receive(frames?.map {
                    CGRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height)
                }, true)
            }
        }
        timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        timer?.tolerance = 0.05
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }

    func stop() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    private nonisolated static func readFrames(pid: pid_t) -> [CGRect]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let barValue = attribute(app, kAXExtrasMenuBarAttribute),
              CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return nil }
        let bar = barValue as! AXUIElement
        guard let children = attribute(bar, kAXChildrenAttribute) as? [AXUIElement],
              children.count <= 150 else { return nil }
        let deadline = Date().addingTimeInterval(0.2)
        var frames: [CGRect] = []
        for child in children {
            guard !Task.isCancelled, Date() < deadline else { return nil }
            if let frame = frame(child) {
                // Ignore offscreen folded items and whole-bar/spacer containers.
                // Screen intersection is evaluated by the organizer, not here.
                if frame.width > 0, frame.width < 1000, frame.height > 0, frame.height <= 64 {
                    frames.append(frame)
                }
            } else {
                // An incomplete layout is unknown, never evidence that it is safe
                // to draw over icons. Retry on the next bounded sample.
                return nil
            }
        }
        // The native overflow arrow can live in an attribute instead of the
        // normal child array. Its clickable rectangle needs the same protection.
        for element in [bar] + children {
            guard !Task.isCancelled, Date() < deadline else { return nil }
            var value: CFTypeRef?
            AXUIElementSetMessagingTimeout(element, 0.05)
            let result = AXUIElementCopyAttributeValue(element, kAXOverflowButtonAttribute as CFString, &value)
            if result == .attributeUnsupported || result == .noValue { continue }
            guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
                  let bounds = frame(value as! AXUIElement) else { return nil }
            frames.append(bounds)
        }
        return frames
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite
        else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
