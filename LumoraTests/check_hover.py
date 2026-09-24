#!/usr/bin/env python3
"""Run the real hover/open/close methods with CLT Swift, without launching Lumora.

AppKit focus and SwiftUI rendering are stubbed; hover and animation-completion
callbacks use real Foundation/Dispatch timing.
Usage: python3 LumoraTests/check_hover.py [path/to/NotchViewModel.swift]
"""
import pathlib
import re
import subprocess
import sys
import tempfile

source_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
    pathlib.Path(__file__).resolve().parents[1] / "Lumora/Core/NotchViewModel.swift"
)
source = source_path.read_text()
methods = []
for name in ("handleMouseMove", "handleMouseDown", "cancelHoverOpen", "cancelHoverClose", "notchOpen", "notchClose", "toggleMenu", "pushTo", "navigateBack"):
    match = re.search(r"(?ms)^    (?:private )?func " + name + r"\(.*?^    }$", source)
    if match:
        methods.append(match.group())
    elif name != "cancelHoverOpen":
        raise AssertionError(f"Cannot find production method {name}")
settings_case = re.search(r"(?ms)^        case \.openSettings:\n(.*?)^        }", source)
assert settings_case, "Cannot find production openSettings shortcut case"
methods.append("    func openSettings() {\n" + settings_case.group(1) + "    }")
toggle_case = re.search(r"(?ms)^        case \.toggleNotch:\n(.*?)^        case \.closeNotch:", source)
assert toggle_case, "Cannot find production toggleNotch shortcut case"
methods.append("    func toggleNotch() {\n" + toggle_case.group(1) + "    }")
interaction_size = re.search(r"(?ms)^    var interactionSize: CGSize \{.*?^    }$", source)
assert interaction_size, "Cannot find production interactionSize"
methods.append(interaction_size.group())

harness = r'''
import Foundation
import CoreGraphics
enum NotchStatus { case closed, opened, popping }
enum NotchOpenReason { case unknown, hover, click, keyboard, notification, boot }
struct SessionState: Equatable { var sessionId: String }
enum Content: Equatable {
    case instances, menu, agents, betaFeatures, chat(SessionState)
    var id: String { String(describing: self) }
}
typealias NotchContentType = Content
struct Geometry {
    func isPointInNotch(_ p: CGPoint, expansionWidth: CGFloat) -> Bool { p.x == 0 }
    func isPointInOpenedPanel(_ p: CGPoint, size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).contains(p)
    }
    func isPointOutsidePanel(_ p: CGPoint, size: CGSize) -> Bool { !isPointInOpenedPanel(p, size: size) }
    func closedPanelSize(expansionWidth: CGFloat) -> CGSize { CGSize(width: 0.5, height: 0.5) }
    var notchScreenRect: CGRect { CGRect(x: 0, y: 0, width: 0.5, height: 0.5) }
}
struct Animation {
    static let panelOpen = Self(), panelClose = Self()
}
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
enum AnimationCompletionCriteria { case removed }
func withAnimation(_ animation: Animation, completionCriteria: AnimationCompletionCriteria,
                   _ body: () -> Void, completion: @escaping () -> Void) {
    body()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: completion)
}
final class PanelPresentation { var size: CGSize? }
class NSRunningApplication {
    var activations = 0
    func activate(options: [Int]) { activations += 1 }
}
enum NSEvent { static var mouseLocation = CGPoint(x: 2, y: 0) }
class Application {
    var modalWindow: Int? = nil
    var isActive = true
}
let NSApp = Application()
class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: NSRunningApplication?
}
final class MenuBarOrganizer {
    static let shared = MenuBarOrganizer()
    var isExpanded = false
    var isYieldingToSystem = false
    var onHide: (() -> Void)?
    func hide() {
        onHide?()
        isExpanded = false
    }
}
final class HoverHarness {
    var status = NotchStatus.closed, openReason = NotchOpenReason.unknown
    var isHovering = false, hoverTimer: DispatchWorkItem?, hoverCloseTimer: DispatchWorkItem?
    var lastMouseLocation: CGPoint?, closedByTapAt: Date?
    var isClosing = false, closingID: UUID?
    let panelPresentation = PanelPresentation()
    var suppressMouseDownClose = false, settingsFocusedIndex = -1
    var geometry = Geometry(), closedNotchExpansionWidth: CGFloat = 0
    var panelSize = CGSize(width: 2, height: 2), keyboardActivateTrigger: UUID?
    var openedSize: CGSize {
        contentType == .menu ? CGSize(width: 2, height: 6) : panelSize
    }
    var isInChatMode: Bool { if case .chat = contentType { return true }; return false }
    var previousActiveApp: NSRunningApplication?, currentChatSession: SessionState?
    var animatedTopCornerRadius = 6, animatedBottomCornerRadius = 12
    var contentType = Content.instances, navigationStack: [Content] = []
    var agentsClaudeDirPickerExpanded = false, agentsContentHeight = 0, agentsBaseHeight = 0
    func move(_ x: CGFloat, y: CGFloat = 0) {
        NSEvent.mouseLocation = CGPoint(x: x, y: y)
        handleMouseMove(NSEvent.mouseLocation)
    }
    func mouseDown() { handleMouseDown() }
__METHODS__
}
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let hover = HoverHarness()
hover.move(0)
wait(0.08)
check(hover.status == .closed, "Crossing the notch should not open it immediately")
wait(0.27)
check(hover.status == .opened && hover.openReason == .hover, "Hover should open within 350 ms")

let rapid = HoverHarness()
rapid.move(0)
let pending = rapid.hoverTimer!
rapid.notchOpen(reason: .click)
rapid.notchClose()
check(pending.isCancelled, "Manual open/close must cancel the pending hover")
wait(0.3)
check(rapid.status == .closed, "A stale hover must not reopen a manually closed notch")

let closed = HoverHarness()
closed.move(0)
closed.notchClose()
wait(0.3)
check(closed.status == .closed, "Closing directly must cancel a pending hover")

let leaving = HoverHarness()
leaving.move(0)
leaving.move(2)
wait(0.3)
check(leaving.status == .closed, "Leaving before the dwell ends must cancel opening")

let popping = HoverHarness()
popping.status = .popping
popping.move(0)
wait(0.3)
check(popping.status == .opened, "Popping must still allow hover expansion")

let changed = HoverHarness()
changed.move(0)
changed.status = .opened
changed.openReason = .notification
wait(0.3)
check(changed.openReason == .notification, "Delayed hover must recheck the current status")

let settingsClosed = HoverHarness(), settingsOpen = HoverHarness(), settingsChat = HoverHarness()
settingsOpen.status = .opened
settingsOpen.contentType = .menu
settingsChat.currentChatSession = SessionState(sessionId: "cached-chat")
for settings in [settingsClosed, settingsOpen, settingsChat] {
    for _ in 0..<2 {
        settings.openSettings()
        check(settings.status == .opened && settings.contentType == .menu,
              "Settings must open the menu from closed, menu, or cached chat and remain open on repeat")
    }
}
check(settingsChat.currentChatSession?.sessionId == "cached-chat", "Opening settings must retain cached chat")
let chat = HoverHarness()
chat.notchOpen(reason: .click)
chat.contentType = .chat(SessionState(sessionId: "wide-chat"))
chat.notchClose()
check(chat.contentType == .chat(SessionState(sessionId: "wide-chat")),
      "Closing must retain the outgoing page instead of reflowing it into the list")
wait(0.45)
chat.notchOpen(reason: .hover)
check(chat.contentType == .chat(SessionState(sessionId: "wide-chat")), "Reopen must restore chat")
chat.contentType = .menu
chat.notchOpen(reason: .click)
check(chat.contentType == .menu, "Repeated open must not replace an already visible page")
chat.notchClose()
chat.notchOpen(reason: .notification)
check(chat.contentType == .instances && chat.currentChatSession == nil,
      "Notifications must open the list instead of restoring chat")
let agents = HoverHarness()
agents.contentType = .agents
agents.agentsClaudeDirPickerExpanded = true
agents.agentsBaseHeight = 100
agents.agentsContentHeight = 188
agents.notchOpen(reason: .click)
check(agents.contentType == .instances && !agents.agentsClaudeDirPickerExpanded && agents.agentsContentHeight == 100,
      "Leaving a retained agents page must reset its transient picker")
// Check the production exit timer using real Dispatch, including events that
// return between the last throttled move and the dismissal deadline.
let exitHover = HoverHarness()
exitHover.move(0)
exitHover.notchOpen(reason: .hover)
exitHover.move(1)
wait(0.2)
check(exitHover.status == .opened, "Moving from the notch into expanded content must remain open")
exitHover.move(2)
wait(0.05)
check(exitHover.status == .opened, "Brief pointer overshoot should not dismiss immediately")
wait(0.2)
check(exitHover.status == .closed, "Leaving the expanded panel must dismiss after the short grace period")

let returnHover = HoverHarness()
returnHover.move(0)
returnHover.notchOpen(reason: .hover)
returnHover.move(2)
let cancelledExit = returnHover.hoverCloseTimer!
returnHover.move(1)
wait(0.2)
check(cancelledExit.isCancelled && returnHover.status == .opened,
      "Returning inside must cancel the pending dismissal")
returnHover.move(2)
NSEvent.mouseLocation = CGPoint(x: 1, y: 0) // Pointer returned, throttle has not delivered it yet.
wait(0.2)
check(returnHover.status == .opened, "A live pointer recheck must beat a stale throttled exit")
returnHover.move(2) // The brief return was entirely coalesced by the event throttle.
wait(0.2)
check(returnHover.status == .closed, "A missed inside event must not disable the next real exit")
returnHover.move(0)
returnHover.notchOpen(reason: .click)
returnHover.move(2)
let supersededExit = returnHover.hoverCloseTimer!
returnHover.notchClose()
returnHover.notchOpen(reason: .click)
wait(0.2)
check(supersededExit.isCancelled && returnHover.status == .opened,
      "An old close must never dismiss a newer open")
returnHover.move(1)
returnHover.move(2)
returnHover.notchOpen(reason: .click)
wait(0.2)
check(returnHover.status == .opened, "Explicit repeated open must also cancel pending dismissal")

for reason in [NotchOpenReason.click, .notification, .boot] {
    let keyboard = HoverHarness()
    keyboard.isHovering = true // Stale hover from a previous opening.
    NSEvent.mouseLocation = CGPoint(x: 2, y: 0)
    keyboard.notchOpen(reason: reason)
    keyboard.move(2)
    wait(0.2)
    check(keyboard.status == .opened, "Opening with the pointer already outside must remain usable")
    keyboard.move(1)
    keyboard.move(2)
    wait(0.2)
    check(keyboard.status == .closed, "After entering, leaving must dismiss any opening reason")
}
let stickyChat = HoverHarness()
stickyChat.move(0)
stickyChat.notchOpen(reason: .click)
stickyChat.contentType = .chat(SessionState(sessionId: "retained-after-hover"))
stickyChat.move(2)
wait(0.2)
check(stickyChat.status == .closed, "Chat must also dismiss on pointer exit")
stickyChat.notchOpen(reason: .click)
check(stickyChat.contentType == .chat(SessionState(sessionId: "retained-after-hover")),
      "Hover dismissal must preserve chat for reopening")

// Feed rendered sizes into the real interaction logic. The native SwiftUI
// check separately verifies that these samples match the animating frame.
let reversing = HoverHarness()
reversing.move(1, y: 1)
reversing.openSettings()
reversing.pushTo(.betaFeatures)
let retainedNavigation = reversing.navigationStack
reversing.panelPresentation.size = CGSize(width: 1.5, height: 1.5)
reversing.move(3, y: 1)
wait(0.2)
check(reversing.status == .closed && reversing.isClosing,
      "Closing must retain an interactive presentation until animation completion")
reversing.move(1.8, y: 1) // Inside the old page, outside the currently visible panel.
check(reversing.status == .closed && reversing.isClosing,
      "Returning only to an already vanished area must not reopen the panel")
reversing.move(1, y: 1)
check(reversing.status == .opened && !reversing.isClosing
      && reversing.contentType == .betaFeatures && reversing.navigationStack == retainedNavigation,
      "Re-entering the visible closing panel must immediately restore its page and back navigation")
wait(0.4)
check(reversing.status == .opened && reversing.navigationStack == retainedNavigation,
      "The interrupted close completion must not erase the resumed navigation")

reversing.notchClose()
reversing.move(1.1, y: 1) // Closing was explicit while the pointer remained inside.
wait(0.05)
check(reversing.status == .closed && reversing.isClosing,
      "A small inside drift must not undo an explicit close or terminal-focus action")
reversing.move(3, y: 1)
reversing.move(1, y: 1)
check(reversing.status == .opened, "A genuine exit and return may interrupt an explicit close")
reversing.notchClose()
NSEvent.mouseLocation = CGPoint(x: 1, y: 1)
reversing.mouseDown()
check(reversing.status == .opened && reversing.navigationStack == retainedNavigation,
      "An explicit click in the still-visible closing panel must also resume it")

let settled = HoverHarness()
settled.move(1, y: 1)
settled.openSettings()
settled.pushTo(.betaFeatures)
settled.panelPresentation.size = CGSize(width: 1.5, height: 1.5)
settled.move(3, y: 1)
settled.notchClose()
wait(0.45)
check(!settled.isClosing && settled.navigationStack.isEmpty
      && settled.interactionSize == settled.geometry.closedPanelSize(expansionWidth: 0),
      "A completed close must release its old hit area and navigation")
settled.move(1, y: 1)
wait(0.25)
check(settled.status == .closed, "A late return to the old expanded area must not reopen a settled notch")
settled.move(0)
wait(0.25)
check(settled.status == .opened && settled.contentType == .instances,
      "After settling, normal notch hover must reopen the default page")

let renewedClose = HoverHarness()
renewedClose.move(1)
renewedClose.openSettings()
renewedClose.pushTo(.betaFeatures)
renewedClose.notchClose()
wait(0.2)
renewedClose.notchOpen(reason: .hover)
renewedClose.notchClose()
wait(0.22) // Old close completes; the newer one is still running.
check(renewedClose.isClosing && renewedClose.navigationStack == retainedNavigation,
      "An old completion must not settle a newer close or clear its retained page")
wait(0.25)
check(!renewedClose.isClosing && renewedClose.navigationStack.isEmpty,
      "The current close completion must perform its cleanup once")

let closingNotification = HoverHarness()
closingNotification.move(1)
closingNotification.openSettings()
closingNotification.pushTo(.betaFeatures)
closingNotification.notchClose()
closingNotification.notchOpen(reason: .notification)
check(closingNotification.status == .opened && !closingNotification.isClosing
      && closingNotification.contentType == .instances && closingNotification.navigationStack.isEmpty,
      "A notification interrupting close must open a fresh list without stale settings navigation")

let modal = HoverHarness()
modal.move(0)
modal.notchOpen(reason: .click)
modal.move(2)
NSApp.modalWindow = 1
wait(0.2)
check(modal.status == .opened, "A folder picker opened during the grace period must stay usable")
modal.move(1)
modal.move(2)
check(modal.hoverCloseTimer == nil, "Moving across a modal must not schedule dismissal")
NSApp.modalWindow = nil
modal.move(1)
modal.move(2)
wait(0.2)
check(modal.status == .closed, "Normal dismissal resumes after the modal closes")
let modalClick = HoverHarness()
modalClick.move(0)
modalClick.notchOpen(reason: .click)
modalClick.contentType = .agents
modalClick.move(2)
let modalPendingExit = modalClick.hoverCloseTimer!
NSApp.modalWindow = 1
modalClick.mouseDown()
check(modalClick.status == .opened && modalClick.contentType == .agents,
      "A click in the native folder picker must not close or replace its parent page")
check(modalPendingExit.isCancelled && modalClick.hoverCloseTimer == nil,
      "Modal clicks must cancel an exit already waiting in the event queue")
NSApp.modalWindow = nil
modalClick.mouseDown()
check(modalClick.status == .closed, "Click-outside dismissal must resume after the picker closes")

let modalClosedClick = HoverHarness()
modalClosedClick.move(0)
let modalPendingOpen = modalClosedClick.hoverTimer!
NSApp.modalWindow = 1
modalClosedClick.mouseDown()
check(modalClosedClick.status == .closed && modalPendingOpen.isCancelled,
      "A modal click over the notch must neither open it nor leave a pending hover open")
NSApp.modalWindow = nil
let modalOpening = HoverHarness()
modalOpening.move(0)
NSApp.modalWindow = 1
wait(0.25)
check(modalOpening.status == .closed, "A pending hover open must not interrupt a new modal")
NSApp.modalWindow = nil

// Revealed menu-bar icons own pointer traffic, including previously queued
// timers. Explicit settings/keyboard requests return ownership to Lumora first.
let organizer = MenuBarOrganizer.shared
let revealingDuringDwell = HoverHarness()
revealingDuringDwell.move(0)
organizer.isExpanded = true
wait(0.25)
check(revealingDuringDwell.status == .closed,
      "A hover already queued before icon reveal must not reopen Lumora")

let iconTraffic = HoverHarness()
iconTraffic.move(0)
iconTraffic.mouseDown()
check(iconTraffic.status == .closed && iconTraffic.hoverTimer == nil,
      "Hover and clicks on revealed icons must not open Lumora")
for reason in [NotchOpenReason.hover, .click, .notification, .boot] {
    iconTraffic.notchOpen(reason: reason)
    check(iconTraffic.status == .closed && organizer.isExpanded,
          "Pointer and notification opens must leave the icon section expanded")
}

organizer.isExpanded = false
let queuedIconClick = HoverHarness()
queuedIconClick.move(0)
let oldIconHover = queuedIconClick.hoverTimer!
organizer.isExpanded = true
queuedIconClick.mouseDown()
check(oldIconHover.isCancelled && queuedIconClick.hoverTimer == nil,
      "A click in the revealed icon section must cancel the old hover-open timer")

organizer.isExpanded = false
let queuedIconExit = HoverHarness()
queuedIconExit.move(0)
queuedIconExit.notchOpen(reason: .click)
queuedIconExit.move(2)
organizer.isExpanded = true
wait(0.2)
check(queuedIconExit.status == .opened,
      "An exit already queued before icon reveal must not act while the organizer owns input")

let explicitOpen = HoverHarness()
var foldedBeforeOpening = false
organizer.onHide = { foldedBeforeOpening = explicitOpen.status == .closed }
explicitOpen.notchOpen()
check(explicitOpen.status == .opened && !organizer.isExpanded && foldedBeforeOpening,
      "Explicit programmatic opening must fold icons before opening Lumora")

let organizerSettings = HoverHarness()
organizer.isExpanded = true
organizer.onHide = { foldedBeforeOpening = organizerSettings.status == .closed }
foldedBeforeOpening = false
organizerSettings.openSettings()
check(organizerSettings.status == .opened && organizerSettings.contentType == .menu
      && !organizer.isExpanded && foldedBeforeOpening,
      "The real Settings command must fold icons first, then open Lumora's settings")
organizer.onHide = nil

// Native menu-bar overlap is not the legacy section. It keeps ownership even
// for explicit opens until the system has finished exposing its icons.
let nativeDwell = HoverHarness()
nativeDwell.move(0)
organizer.isYieldingToSystem = true
wait(0.25)
check(nativeDwell.status == .closed,
      "A pending hover must not reopen Lumora after the system takes the menu bar")
let nativeTraffic = HoverHarness()
nativeTraffic.move(0)
nativeTraffic.mouseDown()
check(nativeTraffic.status == .closed && nativeTraffic.hoverTimer == nil,
      "Native menu-bar hover and clicks must not open the hidden notch")
for reason in [NotchOpenReason.hover, .click, .notification, .boot, .keyboard, .unknown] {
    nativeTraffic.notchOpen(reason: reason)
    check(nativeTraffic.status == .closed && organizer.isYieldingToSystem,
          "All opening reasons must respect the native menu bar's current ownership")
}
nativeTraffic.toggleNotch()
check(nativeTraffic.status == .closed && organizer.isYieldingToSystem,
      "The global toggle must not reveal Lumora over system menu-bar icons")

organizer.isYieldingToSystem = false
let nativeClick = HoverHarness()
nativeClick.move(0)
let nativeOldHover = nativeClick.hoverTimer!
organizer.isYieldingToSystem = true
nativeClick.mouseDown()
check(nativeOldHover.isCancelled && nativeClick.hoverTimer == nil,
      "A native menu-bar click must cancel any pending hover")

organizer.isYieldingToSystem = false
let nativeExit = HoverHarness()
nativeExit.move(0)
nativeExit.notchOpen(reason: .click)
nativeExit.move(2)
organizer.isYieldingToSystem = true
wait(0.2)
nativeExit.mouseDown()
check(nativeExit.status == .opened,
      "Native menu-bar interaction must not trigger a queued exit or outside click")
nativeExit.toggleNotch()
check(nativeExit.status == .closed && organizer.isYieldingToSystem,
      "The global toggle must still let users close a panel hidden by the native menu bar")

organizer.isYieldingToSystem = false
nativeTraffic.move(2)
nativeTraffic.move(0)
wait(0.25)
check(nativeTraffic.status == .opened && nativeTraffic.openReason == .hover,
      "Normal hover opening must resume after native menu-bar ownership ends")

// A navigation/resize moves the boundary, not the pointer. Check actual
// production navigation and mouse handlers, including the throttled-click path.
let resized = HoverHarness()
resized.move(1)
resized.openSettings()
resized.move(1, y: 5) // Experimental Features near the bottom of the tall menu.
resized.mouseDown()
resized.pushTo(.betaFeatures)
resized.move(1, y: 5)
resized.move(1, y: 4.9)
wait(0.2)
check(resized.status == .opened && resized.contentType == .betaFeatures,
      "A shorter destination must remain open while the pointer stays in the old menu area")
resized.move(1, y: 1)
resized.move(1, y: 3)
wait(0.2)
check(resized.status == .closed, "Entering the smaller page must re-arm normal exit dismissal")

let clicked = HoverHarness()
clicked.move(1)
clicked.openSettings()
// Last delivered movement is still at the top; the click is already at the bottom.
NSEvent.mouseLocation = CGPoint(x: 1, y: 5)
clicked.mouseDown()
clicked.pushTo(.betaFeatures)
clicked.move(1, y: 5)
wait(0.2)
check(clicked.status == .opened, "A throttled move must not undo the navigation click baseline")
clicked.navigateBack()
clicked.move(1, y: 7)
wait(0.2)
check(clicked.status == .closed, "After growing around the pointer, a real exit must still close")

let samePage = HoverHarness()
samePage.move(1)
samePage.notchOpen(reason: .click)
samePage.panelSize.height = 6
samePage.move(1, y: 5)
samePage.panelSize.height = 2 // Same-page picker/measurement collapse.
samePage.move(1, y: 4.9)
wait(0.2)
check(samePage.status == .opened, "Same-page height shrink must not count as pointer exit")
samePage.panelSize = CGSize(width: 4, height: 6)
samePage.move(3, y: 1)
samePage.panelSize.width = 2
samePage.move(3.1, y: 1)
wait(0.2)
check(samePage.status == .opened, "Width shrink must not count as pointer exit")
// An explicit click outside still dismisses a panel protected after a resize.
samePage.mouseDown()
check(samePage.status == .closed, "Resize protection must not disable click-outside dismissal")

for changePage in [false, true] {
    let pendingResize = HoverHarness()
    pendingResize.move(1)
    pendingResize.notchOpen(reason: .click)
    pendingResize.move(2)
    if changePage {
        pendingResize.pushTo(.betaFeatures) // Same bounds, new page.
    } else {
        pendingResize.panelSize.height = 1 // Same page, new bounds.
    }
    wait(0.2)
    check(pendingResize.status == .opened, "An old exit timer must not close resized or replaced content")
    pendingResize.move(1)
    pendingResize.move(2)
    wait(0.2)
    check(pendingResize.status == .closed, "After resize cancellation, enter/exit must resume normally")
}

for isActive in [true, false] {
    let originalApp = NSRunningApplication()
    NSWorkspace.shared.frontmostApplication = originalApp
    NSApp.isActive = isActive
    let focus = HoverHarness()
    focus.move(0)
    focus.notchOpen(reason: .hover)
    focus.move(2)
    wait(0.2)
    check(originalApp.activations == (isActive ? 1 : 0),
          "Restore previous focus only while Lumora still owns it")
}
print("PASS: hover timing, visible-frame reversal, completion lifecycle, navigation/resize protection, modal and organizer input ownership, focus and chat retention")
'''.replace("__METHODS__", "\n".join(methods))

with tempfile.TemporaryDirectory(prefix="lumora-hover-check-") as directory:
    swift_file = pathlib.Path(directory) / "check.swift"
    swift_file.write_text(harness)
    subprocess.run(
        ["swift", "-module-cache-path", str(pathlib.Path(directory) / "modules"), str(swift_file)],
        check=True,
    )
