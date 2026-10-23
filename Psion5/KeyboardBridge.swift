import UIKit
import WebKit

/// Takes hardware key presses before WebKit sees them and replays them into
/// the emulator page as Psion keys.
///
/// Handling keys natively, rather than letting WKWebView deliver them, means
/// modifier-only presses (Option for Menu, Cmd for Psion) always arrive, and
/// one physical key can become a Psion chord (Home = Psion + Left).
@MainActor
final class KeyboardBridge {
    static let shared = KeyboardBridge()

    weak var webView: WKWebView?

    /// False while the Claude app is open: keys then go to UIKit as normal,
    /// so the Claude app's text box can take them.
    var routesToEmulator = true
    /// Sees every key press first; returning true swallows the key (both its
    /// press and its release). Used for app shortcuts such as Cmd+Return.
    var shortcutHandler: ((UIKey) -> Bool)?
    private var swallowed: Set<UIKeyboardHIDUsage> = []

    /// Psion keys each held hardware key is pressing.
    private var held: [UIKeyboardHIDUsage: [DOMKey]] = [:]
    /// How many held hardware keys are pressing each Psion key, so Cmd and
    /// Home held together don't release the shared Psion key early.
    private var pressCount: [DOMKey: Int] = [:]

    /// Returns true when the event was a keyboard event and has been handled.
    /// False means UIKit should deliver it as usual.
    func handle(_ event: UIPressesEvent) -> Bool {
        guard let webView else { return false }

        var script = ""
        var sawKey = false
        var forUIKit = false
        for press in event.allPresses {
            guard let key = press.key else { continue }
            sawKey = true
            if press.phase == .began, shortcutHandler?(key) == true {
                swallowed.insert(key.keyCode)
                continue
            }
            if swallowed.contains(key.keyCode) {
                if press.phase == .ended || press.phase == .cancelled { swallowed.remove(key.keyCode) }
                continue
            }
            guard routesToEmulator else {
                forUIKit = true
                continue
            }
            switch press.phase {
            case .began:
                guard held[key.keyCode] == nil, let keys = KeyMap.psionKeys(for: key.keyCode) else { continue }
                held[key.keyCode] = keys
                for k in keys { script += hold(k) }
            case .ended, .cancelled:
                guard let keys = held.removeValue(forKey: key.keyCode) else { continue }
                for k in keys.reversed() { script += lift(k) }
            default:
                break
            }
        }

        if !script.isEmpty {
            webView.evaluateJavaScript(script)
        }
        return sawKey && !forUIKit
    }

    /// Lifts every key, e.g. when the app loses focus mid-press.
    func releaseAll() {
        guard !pressCount.isEmpty else { return }
        let script = pressCount.keys.map { js($0, down: false) }.joined()
        held.removeAll()
        pressCount.removeAll()
        webView?.evaluateJavaScript(script)
    }

    private func hold(_ key: DOMKey) -> String {
        let count = pressCount[key, default: 0]
        pressCount[key] = count + 1
        return count == 0 ? js(key, down: true) : ""
    }

    private func lift(_ key: DOMKey) -> String {
        let count = pressCount[key, default: 0]
        if count <= 1 {
            pressCount.removeValue(forKey: key)
            return count == 1 ? js(key, down: false) : ""
        }
        pressCount[key] = count - 1
        return ""
    }

    private func js(_ key: DOMKey, down: Bool) -> String {
        "psion.key(\(key.keyCode),\(key.location),\(down));"
    }
}
