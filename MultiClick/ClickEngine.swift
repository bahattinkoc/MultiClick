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
    @Published private(set) var points: [ClickPoint] = [] {
        didSet { syncOverlays() }
    }

    /// On-screen marker windows, keyed by point id.
    private var overlays: [UUID: OverlayWindow] = [:]
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

    /// True if the cursor is over our main app window (overlays excluded — they
    /// sit exactly on the click targets and must stay transparent to clicks).
    private func isPointInsideOwnWindow() -> Bool {
        let mouse = NSEvent.mouseLocation // bottom-left global coords
        return NSApp.windows.contains {
            $0.isVisible && !($0 is OverlayWindow) && $0.frame.contains(mouse)
        }
    }

    // MARK: - Marker overlays

    /// Keeps the on-screen markers in sync with `points`.
    private func syncOverlays() {
        let liveIDs = Set(points.map(\.id))

        // Drop markers whose point is gone.
        for (id, window) in overlays where !liveIDs.contains(id) {
            window.orderOut(nil)
            overlays[id] = nil
        }

        // Add markers for new points.
        for point in points where overlays[point.id] == nil {
            let window = OverlayWindow(point: point)
            overlays[point.id] = window
            window.orderFrontRegardless()
        }
    }

    /// Replays a full left click at every recorded point, back to back, then
    /// restores the cursor.
    ///
    /// macOS exposes a single cursor *and* a single left-button state, so a
    /// click only registers as a complete down→up cycle. Two points cannot be
    /// "held" at once (the OS already thinks the button is down), which is why
    /// truly simultaneous / multi-touch clicking is impossible. Instead each
    /// point gets its own complete click in sequence — but the whole sweep
    /// finishes in well under a millisecond, so it reads as instantaneous.
    private func fireClicks(restoringCursorTo origin: CGPoint) {
        guard !points.isEmpty else { return }

        func post(_ type: CGEventType, at point: CGPoint) {
            // A fresh source per event avoids WindowServer coalescing rapid
            // clicks into a single multi-click.
            guard let event = CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            event.post(tap: .cghidEventTap)
        }

        for p in points {
            post(.leftMouseDown, at: p.location)
            post(.leftMouseUp, at: p.location)
        }

        CGWarpMouseCursorPosition(origin)
    }
}
