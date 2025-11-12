import Foundation
import AppKit
import CoreGraphics
import IOKit.hid

let reverseVertical = true
let reverseHorizontal = true
let mouseScrollStepSize: Double = 3.0

enum ScrollEventSource {
    case unknown, mouse, trackpad
}

var mouseTap: MouseTap?

let eventTapCallback: CGEventTapCallBack = { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }
    let tap = Unmanaged<MouseTap>.fromOpaque(userInfo).takeUnretainedValue()
    if let newEvent = tap.handle(event: event, type: type) {
        return Unmanaged.passRetained(newEvent)
    }
    return Unmanaged.passRetained(event)
}


final class MouseTap {
    private var lastTouchTime: UInt64 = 0
    private var touching: Int = 0
    private var lastSource: ScrollEventSource = .unknown

    private var activeTapPort: CFMachPort?
    private var activeTapSource: CFRunLoopSource?
    private var passiveTapPort: CFMachPort?
    private var passiveTapSource: CFRunLoopSource?

    var isActive: Bool {
        return activeTapPort != nil && passiveTapPort != nil
    }

    func start() {
        guard !isActive else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            /* print("Needs accessibility permissions") */
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        passiveTapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: eventTapCallback,
            userInfo: selfPtr
        )

        let activeEventsOfInterest: CGEventMask = (1 << CGEventType.scrollWheel.rawValue) |
                                                 (1 << CGEventType.leftMouseDown.rawValue)

        activeTapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: activeEventsOfInterest,
            callback: eventTapCallback,
            userInfo: selfPtr
        )

        guard let activeTapPort = activeTapPort, let passiveTapPort = passiveTapPort else {
            stop()
            return
        }

        passiveTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, passiveTapPort, 0)
        activeTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, activeTapPort, 0)

        if let passiveTapSource = passiveTapSource, let activeTapSource = activeTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), passiveTapSource, .commonModes)
            CFRunLoopAddSource(CFRunLoopGetMain(), activeTapSource, .commonModes)
        }
    }

    func stop() {
        if let activeTapSource = activeTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), activeTapSource, .commonModes) }
        activeTapSource = nil
        if let activeTapPort = activeTapPort { CFMachPortInvalidate(activeTapPort) }
        activeTapPort = nil
        
        if let passiveTapSource = passiveTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), passiveTapSource, .commonModes) }
        passiveTapSource = nil
        if let passiveTapPort = passiveTapPort { CFMachPortInvalidate(passiveTapPort) }
        passiveTapPort = nil
    }
    
    func handle(event: CGEvent, type: CGEventType) -> CGEvent? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return event }
        let time = getNanoseconds()

        if type.rawValue == NSEvent.EventType.gesture.rawValue { // <<< FIXED
            let touches = nsEvent.touches(matching: .touching, in: nil).count
            if touches >= 2 {
                lastTouchTime = time
                touching = max(touching, touches)
            }
            return event
        }

        if type == .scrollWheel {
            if event.flags.contains(.maskShift) {
                let verticalDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let horizontalDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)

                if horizontalDelta != 0 && verticalDelta == 0 {
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: horizontalDelta)
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                }
                
                let newFlags = event.flags.subtracting(.maskShift)
                event.flags = newFlags
            }
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let touchElapsed = time - lastTouchTime
            let currentTouching = touching
            touching = 0

            let source: ScrollEventSource
            if !isContinuous {
                source = .mouse
            } else if currentTouching >= 2 && touchElapsed < (200_000_000) { //2 fingers touch trackpad .2 seconds
                source = .trackpad
            } else if touchElapsed > (500_000_000) {
                source = .mouse
            } else {
                source = lastSource 
            }
            lastSource = source

            if source == .mouse {
                let axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let axis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                let vmul = reverseVertical ? -1.0 : 1.0
                let hmul = reverseHorizontal ? -1.0 : 1.0
                let verticalMultiplier = vmul * mouseScrollStepSize
                let horizontalMultiplier = hmul * mouseScrollStepSize

                if verticalMultiplier != 1.0 {
                    let newVerticalDelta = Int64(round(Double(axis1) * verticalMultiplier))
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newVerticalDelta)
                }
                if horizontalMultiplier != 1.0 {
                    let newHorizontalDelta = Int64(round(Double(axis2) * horizontalMultiplier))
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: newHorizontalDelta)
                }
            }
        }

        if type == .leftMouseDown {
            if event.flags.contains(.maskControl) {
                let newFlags = event.flags.subtracting(.maskControl)
                event.flags = newFlags
            }
        }
        
        return event
    }
}

func getNanoseconds() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let time = mach_absolute_time()
    return time * UInt64(info.numer) / UInt64(info.denom)
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
