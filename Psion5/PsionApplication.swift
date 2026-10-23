import UIKit

/// Routes hardware keyboard events to the emulator before UIKit hands them to
/// the first responder (which would be WKWebView).
final class PsionApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent, KeyboardBridge.shared.handle(presses) {
            return
        }
        super.sendEvent(event)
    }
}
