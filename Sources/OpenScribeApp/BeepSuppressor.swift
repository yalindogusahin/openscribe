import AppKit
import ObjectiveC

/// Method-swizzles NSWindow.noResponderFor: to suppress NSBeep.
/// macOS calls `noResponder(for:)` whenever an unhandled key action reaches
/// the bottom of the responder chain. The default implementation calls NSBeep
/// for keyDown selectors. Replacing it with a no-op silences the system beep
/// app-wide without affecting key dispatch.
enum BeepSuppressor {
    static let install: Void = {
        guard
            let original = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("noResponderFor:")),
            let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.swz_noResponderFor(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

extension NSWindow {
    @objc fileprivate func swz_noResponderFor(_ eventSelector: Selector) {
        // Intentionally a no-op: suppress NSBeep.
    }
}
