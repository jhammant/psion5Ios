import UIKit
import WebKit

/// Runs the Claude app: the on-screen button, the Claude screen over the
/// Psion's LCD, its keyboard shortcuts, and typing answers into the Psion.
@MainActor
final class ClaudeController {
    private let webView: WKWebView
    private let chat = ClaudeChat()
    private let appView = ClaudeAppView()
    private let button = UIButton(type: .custom)
    private let typingLabel = UILabel()

    private(set) var isOpen = false
    private var isTyping = false
    /// Where the Psion's LCD is, and how far up the on-screen keyboard (if
    /// any) reaches, both in container coordinates.
    private var lcdFrame: CGRect = .zero
    private var keyboardTop: CGFloat = .infinity

    init(container: UIView, webView: WKWebView) {
        self.webView = webView

        appView.isHidden = true
        appView.onSubmit = { [weak self] in self?.submit($0) }
        appView.onTypeIntoPsion = { [weak self] in self?.typeIntoPsion() }
        appView.onNewChat = { [weak self] in self?.newChat() }
        appView.onChangeKey = { [weak self] in self?.changeKey() }
        container.addSubview(appView)

        button.setTitle("Claude", for: .normal)
        button.setTitleColor(ClaudeAppView.ink, for: .normal)
        button.titleLabel?.font = ClaudeAppView.font(14, bold: true)
        button.backgroundColor = ClaudeAppView.lcd
        button.layer.borderColor = ClaudeAppView.ink.cgColor
        button.layer.borderWidth = 1.5
        button.layer.cornerRadius = 4
        button.accessibilityHint = "Opens Claude. Shortcut: Command Return."
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        container.addSubview(button)

        typingLabel.text = "Typing... Esc stops"
        typingLabel.textAlignment = .center
        typingLabel.textColor = ClaudeAppView.ink
        typingLabel.font = ClaudeAppView.font(13, bold: true)
        typingLabel.backgroundColor = ClaudeAppView.lcd
        typingLabel.layer.cornerRadius = 4
        typingLabel.layer.masksToBounds = true
        typingLabel.isHidden = true
        container.addSubview(typingLabel)

        KeyboardBridge.shared.shortcutHandler = { [weak self] key in
            self?.handleShortcut(key) ?? false
        }

        // Without a hardware keyboard, iOS shows its own over the bottom of
        // the screen; lift the Claude screen above it.
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            MainActor.assumeIsolated {
                guard let self, let container = self.appView.superview else { return }
                let local = container.convert(frame, from: nil)
                self.keyboardTop = local.minY < container.bounds.maxY ? local.minY : .infinity
                self.placeAppView()
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardTop = .infinity
                self?.placeAppView()
            }
        }
    }

    // MARK: - Layout

    /// The page reports where the LCD is (in points, since the web view isn't
    /// zoomed), so the Claude screen can cover exactly that area.
    func lcdMoved(to frame: CGRect, scale: CGFloat) {
        lcdFrame = frame
        appView.scale = scale
        placeAppView()
    }

    private func placeAppView() {
        var frame = lcdFrame
        if frame.maxY > keyboardTop - 4 {
            frame.origin.y = max(0, keyboardTop - 4 - frame.height)
        }
        appView.frame = frame
    }

    /// Puts the button in the top-right corner, in the black margin above the Psion.
    func layoutChrome(in bounds: CGRect, safeArea: UIEdgeInsets) {
        let size = CGSize(width: 78, height: 26)
        let origin = CGPoint(x: bounds.maxX - safeArea.right - size.width - 10, y: safeArea.top + 6)
        button.frame = CGRect(origin: origin, size: size)
        let typingWidth: CGFloat = 170
        typingLabel.frame = CGRect(x: button.frame.maxX - typingWidth, y: origin.y, width: typingWidth, height: size.height)
    }

    // MARK: - Open and close

    @objc func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        if isTyping { stopTyping() }
        isOpen = true
        KeyboardBridge.shared.releaseAll()
        KeyboardBridge.shared.routesToEmulator = false
        if APIKeyStore.load() == nil {
            appView.showKeyEntry()
        } else if appView.mode == .chat {
            appView.showChat()
        }
        appView.isHidden = false
        appView.superview?.bringSubviewToFront(appView)
        appView.focusInput()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        appView.unfocus()
        appView.isHidden = true
        KeyboardBridge.shared.routesToEmulator = true
    }

    // MARK: - Chat

    private func submit(_ value: String) {
        if appView.mode == .enterKey {
            saveKey(value)
            return
        }
        guard let apiKey = APIKeyStore.load() else {
            appView.showKeyEntry()
            return
        }
        guard !chat.isBusy else { return }

        appView.appendQuestion(value)
        appView.beginAnswer()
        appView.setStatus("Thinking...")
        chat.send(value, apiKey: apiKey) { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let delta):
                self.appView.appendAnswer(delta)
                self.appView.setStatus("Writing...")
            case .finished(let cutShort):
                self.appView.endAnswer(note: cutShort ? "(The answer was cut short.)" : nil)
                self.appView.setStatus("Ctrl+T types\nit in")
            case .failed(let message):
                self.appView.endAnswer(error: message)
                self.appView.setStatus(nil)
            }
        }
    }

    private func saveKey(_ key: String) {
        guard key.hasPrefix("sk-ant-") else {
            appView.showKeyEntry(reason: "That doesn't look like an Anthropic API key. They start with sk-ant-.")
            return
        }
        guard APIKeyStore.save(key) else {
            appView.showKeyEntry(reason: "Couldn't save the key to the Keychain. Try again.")
            return
        }
        appView.clear()
        appView.showChat()
        appView.setStatus("Key saved")
    }

    private func newChat() {
        chat.reset()
        appView.clear()
        appView.showChat()
        appView.setStatus(nil)
    }

    private func changeKey() {
        chat.reset()
        appView.showKeyEntry()
        appView.setStatus(nil)
    }

    // MARK: - Typing into the Psion

    private func typeIntoPsion() {
        guard let answer = chat.lastAnswer else {
            appView.setStatus("No answer\nto type yet")
            return
        }
        close()
        isTyping = true
        button.isHidden = true
        typingLabel.isHidden = false
        webView.callAsyncJavaScript("return psion.typeText(text)", arguments: ["text": answer], in: nil, in: .page) { [weak self] result in
            if case .success(let typed) = result, (typed as? Int ?? 0) > 0 { return }
            self?.typingFinished()
        }
    }

    private func stopTyping() {
        webView.evaluateJavaScript("psion.stopTyping()")
        typingFinished()
    }

    /// Called when the page has typed everything (or typing was stopped).
    func typingFinished() {
        isTyping = false
        typingLabel.isHidden = true
        button.isHidden = false
    }

    // MARK: - Shortcuts

    private func handleShortcut(_ key: UIKey) -> Bool {
        let mods = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
        if key.keyCode == .keyboardReturnOrEnter && mods == .command {
            toggle()
            return true
        }
        if isTyping && key.keyCode == .keyboardEscape {
            stopTyping()
            return true
        }
        guard isOpen else { return false }
        switch (key.keyCode, mods) {
        case (.keyboardEscape, []): close()
        case (.keyboardT, .control): typeIntoPsion()
        case (.keyboardN, .control): newChat()
        case (.keyboardK, .control): changeKey()
        case (.keyboardUpArrow, []): appView.scrollTranscript(lines: -3)
        case (.keyboardDownArrow, []): appView.scrollTranscript(lines: 3)
        default: return false
        }
        return true
    }
}
