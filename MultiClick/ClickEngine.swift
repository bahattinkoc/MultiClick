//
//  ClickEngine.swift
//  MultiClick
//
//  Core engine: captures right/left clicks via a CGEventTap and replays
//  left clicks at every recorded position.
//

import Foundation
import CoreGraphics
import AppKit
import Combine

/// A recorded click target. Coordinates are in global Quartz space
/// (top-left origin), matching what CGEvent uses.
struct ClickPoint: Identifiable, Equatable {
    let id = UUID()
    var location: CGPoint
}

final class ClickEngine: ObservableObject {

    /// Targets the user marked with a right-click.
    @Published private(set) var points: [ClickPoint] = []
    /// Whether the tap is live (right-click records, left-click fires).
    @Published private(set) var isArmed = false
    /// Cached accessibility-permission state for the UI.
    @Published private(set) var hasPermission = AXIsProcessTrusted()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Tag stamped on our synthetic events so the tap can ignore them
    /// (otherwise replayed clicks would re-trigger the engine).
    private static let syntheticTag: Int64 = 0x4D_43_4C_4B // "MCLK"

    // MARK: - Permissions

    /// Returns true if granted. When not granted, shows the system prompt.
    @discardableResult
    func refreshPermission(prompt: Bool = false) -> Bool {
        let granted: Bool
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            granted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        } else {
            granted = AXIsProcessTrusted()
        }
        hasPermission = granted
        return granted
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Arming

    func toggleArmed() {
        isArmed ? disarm() : arm()
    }

    func arm() {
        guard !isArmed else { return }
        guard refreshPermission(prompt: true) else { return }
        guard installTap() else { return }
        isArmed = true
    }

    func disarm() {
        guard isArmed else { return }
        removeTap()
        isArmed = false
    }

    // MARK: - Points

    func removePoint(_ point: ClickPoint) {
        points.removeAll { $0.id == point.id }
    }

    func clearPoints() {
        points.removeAll()
    }

    // MARK: - Event tap

    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ClickEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    private func removeTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Runs on the main thread (tap is attached to the main run loop).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS can silently disable the tap (timeout / user input); revive it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Never re-process our own replayed clicks.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag {
            return Unmanaged.passUnretained(event)
        }

        // Esc acts as a panic / disarm key.
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 { // Escape
                DispatchQueue.main.async { [weak self] in self?.disarm() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Let interactions with our own window pass through untouched, so the
        // Start/Stop button stays clickable and clicks in-app don't fire.
        if isPointInsideOwnWindow() {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .rightMouseDown:
            let location = event.location
            DispatchQueue.main.async { [weak self] in
                self?.points.append(ClickPoint(location: location))
            }
            return nil // swallow: no context menu
        case .rightMouseUp:
            return nil
        case .leftMouseDown:
            let origin = event.location
            DispatchQueue.main.async { [weak self] in
                self?.fireClicks(restoringCursorTo: origin)
            }
            return nil // swallow: the trigger click does nothing itself
        case .leftMouseUp:
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// True if the cursor is currently over one of our visible windows.
    private func isPointInsideOwnWindow() -> Bool {
        let mouse = NSEvent.mouseLocation // bottom-left global coords
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(mouse) }
    }

    /// Replays a left click at every recorded point, then restores the cursor.
    private func fireClicks(restoringCursorTo origin: CGPoint) {
        guard !points.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for point in points {
            for mouseType in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: mouseType,
                    mouseCursorPosition: point.location,
                    mouseButton: .left
                ) else { continue }
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
                event.post(tap: .cghidEventTap)
            }
        }
        CGWarpMouseCursorPosition(origin)
    }
}
