import UIKit

/// A key as Emscripten's SDL layer sees it: a DOM `keyCode` plus `location`
/// (1 = left-hand modifier, 2 = right-hand modifier, 0 = everything else).
struct DOMKey: Hashable {
    let keyCode: Int
    let location: Int

    init(_ keyCode: Int, location: Int = 0) {
        self.keyCode = keyCode
        self.location = location
    }
}

/// Maps hardware keys to the Psion 5mx keys WindEmu emulates.
///
/// WindEmu's own mapping (WindWasm/main.cpp) covers letters, digits, Esc,
/// Tab, Enter, Backspace, Space, ' , . and arrows, with Shift and Ctrl as
/// themselves, Option as Menu and Cmd as the Psion (Fn) key. The emulated
/// keyboard matrix only has a left Ctrl and a left Psion key, so right-hand
/// Cmd and Ctrl are sent as their left-hand twins.
///
/// Keys the Psion keyboard doesn't have are turned into the Psion chord that
/// does the same job.
enum KeyMap {
    static let ctrl = DOMKey(17, location: 1)
    static let leftShift = DOMKey(16, location: 1)
    static let rightShift = DOMKey(16, location: 2)
    static let menu = DOMKey(18, location: 1)
    static let psion = DOMKey(91, location: 1)

    static let backspace = DOMKey(8)
    static let escape = DOMKey(27)
    static let left = DOMKey(37)
    static let up = DOMKey(38)
    static let right = DOMKey(39)
    static let down = DOMKey(40)

    /// The Psion keys to hold down for a hardware key, modifiers first.
    /// Returns nil for keys with no Psion equivalent.
    static func psionKeys(for usage: UIKeyboardHIDUsage) -> [DOMKey]? {
        let raw = usage.rawValue
        switch raw {
        case UIKeyboardHIDUsage.keyboardA.rawValue...UIKeyboardHIDUsage.keyboardZ.rawValue:
            return [DOMKey(65 + raw - UIKeyboardHIDUsage.keyboardA.rawValue)]
        case UIKeyboardHIDUsage.keyboard1.rawValue...UIKeyboardHIDUsage.keyboard9.rawValue:
            return [DOMKey(49 + raw - UIKeyboardHIDUsage.keyboard1.rawValue)]
        case UIKeyboardHIDUsage.keypad1.rawValue...UIKeyboardHIDUsage.keypad9.rawValue:
            return [DOMKey(49 + raw - UIKeyboardHIDUsage.keypad1.rawValue)]
        default:
            break
        }

        switch usage {
        case .keyboard0, .keypad0: return [DOMKey(48)]
        case .keyboardReturnOrEnter, .keypadEnter: return [DOMKey(13)]
        case .keyboardEscape: return [escape]
        case .keyboardDeleteOrBackspace: return [backspace]
        case .keyboardTab: return [DOMKey(9)]
        case .keyboardSpacebar: return [DOMKey(32)]
        case .keyboardQuote: return [DOMKey(222)]
        case .keyboardComma: return [DOMKey(188)]
        case .keyboardPeriod, .keypadPeriod: return [DOMKey(190)]

        case .keyboardLeftArrow: return [left]
        case .keyboardRightArrow: return [right]
        case .keyboardUpArrow: return [up]
        case .keyboardDownArrow: return [down]

        case .keyboardLeftShift: return [leftShift]
        case .keyboardRightShift: return [rightShift]
        case .keyboardLeftControl, .keyboardRightControl: return [ctrl]
        case .keyboardLeftAlt, .keyboardRightAlt: return [menu]
        case .keyboardLeftGUI, .keyboardRightGUI: return [psion]

        // Remaps for keys the Psion doesn't have.
        // ` sits where the Psion's Esc does, and many folding keyboards have no Esc.
        case .keyboardGraveAccentAndTilde: return [escape]
        case .keyboardDeleteForward: return [rightShift, backspace]
        case .keyboardHome: return [psion, left]
        case .keyboardEnd: return [psion, right]
        case .keyboardPageUp: return [psion, up]
        case .keyboardPageDown: return [psion, down]

        default: return nil
        }
    }
}
