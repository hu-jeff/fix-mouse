import Foundation
import AppKit
import CoreGraphics
import IOKit.hid

let reverseVertical = true
let reverseHorizontal = true
let mouseScrollStepSize: Double = 3.0

// A scroll-wheel CGEvent is attributed to a mouse if a physical wheel HID input
// was seen within this window just before it.
let mouseScrollAttributionWindow: UInt64 = 100_000_000 // 100ms in nanoseconds

let hidOptions = IOOptionBits(0) // kIOHIDOptionsTypeNone

enum ScrollEventSource {
    case unknown, mouse, trackpad
}

// mach_timebase is constant for the life of the process, so fetch it once.
let timebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func getNanoseconds() -> UInt64 {
    return mach_absolute_time() * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
}

/// Watches raw HID input from pointer devices and records when a physical
/// scroll wheel (or tilt/AC-Pan) last moved.
///
/// Trackpads and the Magic Mouse never emit Wheel/AC-Pan HID usages — macOS
/// synthesizes their scrolling from the touch surface — so the mere arrival of
/// one of these usages is a reliable, device-level signal that the scroll came
/// from a wheel mouse. This is far more robust than inferring the source from
/// event continuity and trackpad touch timing.
final class MouseScrollDetector {
    private var manager: IOHIDManager?
    private(set) var lastMouseScrollTime: UInt64 = 0

    func start() {
        // Reading raw HID input requires Input Monitoring permission on 10.15+.
        if #available(macOS 10.15, *) {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, hidOptions)

        // Only attach to pointer-like devices (mice, trackballs).
        let deviceMatches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02], // Generic Desktop / Mouse
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x01], // Generic Desktop / Pointer
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, deviceMatches as CFArray)

        // Only fire the callback for wheel / horizontal-pan inputs.
        let valueMatches: [[String: Int]] = [
            [kIOHIDElementUsagePageKey: 0x01, kIOHIDElementUsageKey: 0x38],  // Generic Desktop / Wheel
            [kIOHIDElementUsagePageKey: 0x0C, kIOHIDElementUsageKey: 0x238], // Consumer / AC Pan (horizontal)
        ]
        IOHIDManagerSetInputValueMatchingMultiple(manager, valueMatches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context = context else { return }
            let detector = Unmanaged<MouseScrollDetector>.fromOpaque(context).takeUnretainedValue()
            // A zero value is a no-movement report; ignore it.
            if IOHIDValueGetIntegerValue(value) != 0 {
                detector.lastMouseScrollTime = getNanoseconds()
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, hidOptions)
        self.manager = manager
    }

    func stop() {
        guard let manager = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, hidOptions)
        self.manager = nil
    }

    func scrolledRecently(now: UInt64) -> Bool {
        return now &- lastMouseScrollTime < mouseScrollAttributionWindow
    }
}

var mouseTap: MouseTap?

let eventTapCallback: CGEventTapCallBack = { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<MouseTap>.fromOpaque(userInfo).takeUnretainedValue()
    if let newEvent = tap.handle(event: event, type: type) {
        return Unmanaged.passUnretained(newEvent)
    }
    return Unmanaged.passUnretained(event)
}

final class MouseTap {
    private var tapPort: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let detector = MouseScrollDetector()

    var isActive: Bool {
        return tapPort != nil
    }

    func start() {
        guard !isActive else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            /* print("Needs accessibility permissions") */
            return
        }

        detector.start()

        let eventsOfInterest: CGEventMask = (1 << CGEventType.scrollWheel.rawValue) |
                                            (1 << CGEventType.leftMouseDown.rawValue)

        guard let tapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            detector.stop()
            return
        }

        self.tapPort = tapPort
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
        if let tapSource = tapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tapPort, enable: true)
    }

    func stop() {
        if let tapSource = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        if let tapPort = tapPort { CFMachPortInvalidate(tapPort) }
        tapPort = nil
        detector.stop()
    }

    func handle(event: CGEvent, type: CGEventType) -> CGEvent? {
        // The system disables an active tap if the callback is too slow or under
        // heavy input. Re-enable it so the app keeps working without a restart.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort = tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return event
        }

        if type == .scrollWheel {
            let time = getNanoseconds()
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

            let source: ScrollEventSource
            if detector.scrolledRecently(now: time) {
                // A physical wheel HID input just arrived for this scroll.
                source = .mouse
            } else if !isContinuous {
                // Line-based (non-pixel) scrolling only comes from wheel mice.
                // Fallback for when HID detection is unavailable (e.g. no Input
                // Monitoring permission).
                source = .mouse
            } else {
                // Continuous scrolling with no recent wheel HID input: a trackpad
                // (or Magic Mouse), including its gesture and momentum phases.
                source = .trackpad
            }

            if source == .mouse {
                applyMouseScrollTransforms(to: event)
            }
        }

        if type == .leftMouseDown {
            // Prevent CTRL+Left-Click from becoming a right-click.
            if event.flags.contains(.maskControl) {
                event.flags = event.flags.subtracting(.maskControl)
            }
        }

        return event
    }

    private func applyMouseScrollTransforms(to event: CGEvent) {
        // SHIFT+scroll on a mouse is turned into horizontal scrolling by macOS.
        // Undo that by moving the horizontal line delta back onto the vertical
        // axis; CoreGraphics recomputes the matching fixed-point/pixel deltas.
        if event.flags.contains(.maskShift) {
            let verticalLine = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let horizontalLine = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            if horizontalLine != 0 && verticalLine == 0 {
                event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: horizontalLine)
            }
            event.flags = event.flags.subtracting(.maskShift)
        }

        let verticalFactor = (reverseVertical ? -1.0 : 1.0) * mouseScrollStepSize
        let horizontalFactor = (reverseHorizontal ? -1.0 : 1.0) * mouseScrollStepSize

        transformAxis(event,
                      line: .scrollWheelEventDeltaAxis1,
                      fixedPt: .scrollWheelEventFixedPtDeltaAxis1,
                      point: .scrollWheelEventPointDeltaAxis1,
                      by: verticalFactor)
        transformAxis(event,
                      line: .scrollWheelEventDeltaAxis2,
                      fixedPt: .scrollWheelEventFixedPtDeltaAxis2,
                      point: .scrollWheelEventPointDeltaAxis2,
                      by: horizontalFactor)
    }

    private func transformAxis(_ event: CGEvent,
                               line: CGEventField,
                               fixedPt: CGEventField,
                               point: CGEventField,
                               by factor: Double) {
        // For a standard wheel, the integer line delta is the source of truth:
        // setting it makes CoreGraphics regenerate the fixed-point and pixel
        // deltas with a consistent sign and magnitude, so we must NOT touch
        // those afterwards (doing so double-applies the reversal).
        let lineValue = event.getIntegerValueField(line)
        if lineValue != 0 {
            event.setIntegerValueField(line, value: Int64(round(Double(lineValue) * factor)))
            return
        }

        // High-resolution / pixel-based mice send no line delta, so there is
        // nothing for CG to recompute from — scale the continuous deltas here.
        let fixedValue = event.getDoubleValueField(fixedPt)
        if fixedValue != 0 {
            event.setDoubleValueField(fixedPt, value: fixedValue * factor)
        }
        let pointValue = event.getIntegerValueField(point)
        if pointValue != 0 {
            event.setIntegerValueField(point, value: Int64(round(Double(pointValue) * factor)))
        }
    }
}

func signalHandler(signal: Int32) {
    mouseTap?.stop()
    CFRunLoopStop(CFRunLoopGetCurrent())
}

signal(SIGINT, signalHandler)
signal(SIGTERM, signalHandler)

mouseTap = MouseTap()
mouseTap?.start()

if mouseTap?.isActive == true {
    CFRunLoopRun()
} else {
    exit(1)
}
