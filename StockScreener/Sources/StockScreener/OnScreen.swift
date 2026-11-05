import AppKit

/// Is this view actually being looked at? (app in front, window not hidden behind others / minimised)
/// Chart windows poll TradingView several times a second to keep charts in sync — only while you can see them.
@MainActor enum OnScreen {
    static func visible(_ v: NSView?) -> Bool {
        guard NSApp.isActive, let w = v?.window, w.isVisible, !w.isMiniaturized else { return false }
        return w.occlusionState.contains(.visible)
    }
}
