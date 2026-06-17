//
//  OverlayWindow.swift
//  MultiClick
//
//  Floating, click-through marker shown on screen at each recorded point.
//

import SwiftUI
import AppKit

/// A borderless, transparent, always-on-top window that shows a plain mouse
/// cursor icon at a recorded click location. It ignores mouse events so it
/// never interferes with recording or firing.
final class OverlayWindow: NSWindow {
    /// The real system cursor's natural size, so the marker matches it 1:1.
    private static let markerSize = NSCursor.arrow.image.size

    init(point: ClickPoint) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.markerSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true            // click-through
        level = .screenSaver                 // float above ordinary windows
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: MarkerView())
        host.frame = NSRect(origin: .zero, size: Self.markerSize)
        contentView = host

        setFrameOrigin(Self.bottomLeftOrigin(for: point.location))
    }

    /// Converts a global Quartz point (top-left origin) into the Cocoa
    /// bottom-left origin used by `setFrameOrigin`, aligning the cursor's hot
    /// spot (the arrow tip) exactly on the clicked point.
    private static func bottomLeftOrigin(for quartzPoint: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let hotSpot = NSCursor.arrow.hotSpot // image coords, top-left origin
        return NSPoint(
            x: quartzPoint.x - hotSpot.x,
            y: primaryHeight - quartzPoint.y - markerSize.height + hotSpot.y
        )
    }
}

/// The marker: the system mouse-cursor icon at its natural size.
private struct MarkerView: View {
    var body: some View {
        Image(nsImage: NSCursor.arrow.image)
    }
}
