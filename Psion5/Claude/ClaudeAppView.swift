import UIKit

/// The Claude app, drawn over the Psion's LCD in the Psion's own style: a
/// bordered pane with an "Ask:" box like Help's Find box, and a toolbar down
/// the right like the built-in apps.
///
/// Layout is in LCD pixels (640x240) times `scale`, so it lines up with the
/// emulated screen on either of the Duo's displays.
final class ClaudeAppView: UIView, UITextFieldDelegate {
    enum Mode { case chat, enterKey }

    var onSubmit: ((String) -> Void)?
    var onTypeIntoPsion: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onChangeKey: (() -> Void)?
    var onTranscriptTapped: (() -> Void)?

    private(set) var mode: Mode = .chat
    var scale: CGFloat = 1 { didSet { if scale != oldValue { restyle() } } }

    // The Psion's four greys, sampled from the emulator's screen.
    static let lcd = UIColor(red: 153 / 255, green: 170 / 255, blue: 136 / 255, alpha: 1)
    static let light = UIColor(red: 123 / 255, green: 136 / 255, blue: 109 / 255, alpha: 1)
    static let mid = UIColor(red: 102 / 255, green: 113 / 255, blue: 90 / 255, alpha: 1)
    static let ink = UIColor.black

    private let pane = UIView()
    private let transcript = UITextView()
    private let askLabel = UILabel()
    private let inputBox = UIView()
    private let input = UITextField()
    private let toolbarTitle = UILabel()
    private let statusLabel = UILabel()
    private lazy var buttons: [UIButton] = [
        makeButton("Type into\nPsion", action: #selector(typeTapped)),
        makeButton("New chat", action: #selector(newChatTapped)),
        makeButton("API key", action: #selector(keyTapped)),
    ]

    private let text = NSMutableAttributedString()
    /// Where the reply being streamed starts in `text`, and whether its
    /// "Thinking..." placeholder is still showing.
    private var answerStart: Int?
    private var showingPlaceholder = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.lcd
        layer.borderColor = Self.ink.cgColor

        pane.layer.borderColor = Self.ink.cgColor
        addSubview(pane)

        transcript.backgroundColor = .clear
        transcript.isEditable = false
        transcript.isSelectable = false
        transcript.textContainer.lineFragmentPadding = 0
        transcript.showsVerticalScrollIndicator = true
        transcript.indicatorStyle = .black
        transcript.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(transcriptTapped)))
        pane.addSubview(transcript)

        askLabel.text = "Ask:"
        askLabel.textColor = Self.ink
        pane.addSubview(askLabel)

        inputBox.backgroundColor = Self.lcd
        inputBox.layer.borderColor = Self.ink.cgColor
        pane.addSubview(inputBox)

        input.textColor = Self.ink
        input.tintColor = Self.ink
        input.borderStyle = .none
        input.autocorrectionType = .no
        input.spellCheckingType = .no
        input.returnKeyType = .send
        input.delegate = self
        inputBox.addSubview(input)

        toolbarTitle.text = "Claude"
        toolbarTitle.textAlignment = .center
        toolbarTitle.textColor = Self.ink
        toolbarTitle.layer.borderColor = Self.ink.cgColor
        addSubview(toolbarTitle)

        buttons.forEach(addSubview)

        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.textColor = Self.ink
        statusLabel.layer.borderColor = Self.ink.cgColor
        addSubview(statusLabel)
        setStatus(nil)

        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = scale
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        // Matches the proportions of Jotter and Help: content pane on the
        // left, an 82px toolbar on the right.
        pane.frame = r(3, 3, 549, 234)
        transcript.frame = r(8, 6, 535, 196)
        transcript.textContainerInset = .zero
        askLabel.frame = r(8, 207, 34, 20)
        inputBox.frame = r(42, 205, 499, 22)
        input.frame = CGRect(x: 4 * s, y: 0, width: inputBox.bounds.width - 8 * s, height: inputBox.bounds.height)
        toolbarTitle.frame = r(556, 3, 81, 22)
        for (i, button) in buttons.enumerated() {
            button.frame = r(556, 29 + CGFloat(i) * 38, 81, 34)
        }
        statusLabel.frame = r(556, 147, 81, 90)
    }

    private func restyle() {
        let s = scale
        let border = max(1, s)
        layer.borderWidth = 0
        pane.layer.borderWidth = 2 * border
        inputBox.layer.borderWidth = border
        toolbarTitle.layer.borderWidth = border
        statusLabel.layer.borderWidth = border
        askLabel.font = Self.font(13 * s, bold: true)
        input.font = Self.font(13 * s)
        toolbarTitle.font = Self.font(12 * s, bold: true)
        statusLabel.font = Self.font(10 * s)
        for button in buttons {
            button.titleLabel?.font = Self.font(10.5 * s, bold: true)
            button.layer.borderWidth = border
        }
        restyleTranscript()
        setNeedsLayout()
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "Arial-BoldMT" : "ArialMT", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private func makeButton(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .custom)
        button.setTitle(title, for: .normal)
        button.setTitleColor(Self.ink, for: .normal)
        button.setTitleColor(Self.lcd, for: .highlighted)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.backgroundColor = Self.light
        button.layer.borderColor = Self.ink.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Modes and status

    func showChat() {
        mode = .chat
        input.isSecureTextEntry = false
        input.text = ""
        input.attributedPlaceholder = placeholder("Type a question and press Enter")
        if text.length == 0 {
            appendLine("Ask Claude anything. Enter sends; Esc goes back to the Psion.", style: .note)
            appendLine("Ctrl+T types the last answer into the Psion app you were using. Ctrl+N starts a new chat.", style: .note)
        }
    }

    func showKeyEntry(reason: String? = nil) {
        mode = .enterKey
        clear()
        if let reason { appendLine(reason, style: .error) }
        appendLine("Claude needs an Anthropic API key. Create one at console.anthropic.com (Settings, API keys) and paste it below.", style: .note)
        appendLine("It's stored in this phone's Keychain and only sent to Anthropic.", style: .note)
        input.isSecureTextEntry = true
        input.text = ""
        input.attributedPlaceholder = placeholder("Paste your API key (sk-ant-...) and press Enter")
    }

    func setStatus(_ status: String?) {
        statusLabel.text = status ?? "\(ClaudeChat.modelName)\n"
    }

    func focusInput() {
        input.becomeFirstResponder()
    }

    func unfocus() {
        input.resignFirstResponder()
    }

    func scrollTranscript(lines: Int) {
        let step = Self.font(13 * scale).lineHeight * CGFloat(lines)
        let maxY = max(0, transcript.contentSize.height - transcript.bounds.height)
        let y = min(maxY, max(0, transcript.contentOffset.y + step))
        transcript.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    private func placeholder(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.foregroundColor: Self.mid, .font: Self.font(13 * scale)])
    }

    // MARK: - Transcript

    private enum Style: String {
        case question, answer, note, error
    }

    private static let styleKey = NSAttributedString.Key("psionStyle")

    func clear() {
        text.setAttributedString(NSAttributedString())
        answerStart = nil
        showingPlaceholder = false
        render()
    }

    func appendQuestion(_ question: String) {
        appendLine("> " + question, style: .question)
    }

    func beginAnswer() {
        answerStart = text.length
        showingPlaceholder = true
        appendLine("Thinking...", style: .note)
    }

    func appendAnswer(_ delta: String) {
        guard let start = answerStart else { return }
        if showingPlaceholder {
            text.deleteCharacters(in: NSRange(location: start, length: text.length - start))
            showingPlaceholder = false
        }
        text.append(NSAttributedString(string: delta, attributes: [Self.styleKey: Style.answer.rawValue]))
        render()
    }

    func endAnswer(note: String? = nil, error: String? = nil) {
        if let start = answerStart, showingPlaceholder || error != nil {
            // A failed reply's partial text is discarded, not shown as an answer.
            text.deleteCharacters(in: NSRange(location: start, length: text.length - start))
        }
        answerStart = nil
        showingPlaceholder = false
        if !text.string.hasSuffix("\n") && text.length > 0 { text.append(NSAttributedString(string: "\n")) }
        if let note { appendLine(note, style: .note) }
        if let error { appendLine(error, style: .error) }
        text.append(NSAttributedString(string: "\n"))
        render()
    }

    private func appendLine(_ line: String, style: Style) {
        text.append(NSAttributedString(string: line + "\n", attributes: [Self.styleKey: style.rawValue]))
        render()
    }

    /// Applies fonts for the current scale; styles are stored as a custom
    /// attribute so the transcript can be re-rendered when the scale changes.
    private func restyleTranscript() {
        let s = scale
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 3 * s
        text.enumerateAttribute(Self.styleKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let style = Style(rawValue: value as? String ?? "") ?? .answer
            let font: UIFont
            let color: UIColor
            switch style {
            case .question: font = Self.font(13 * s, bold: true); color = Self.ink
            case .answer: font = Self.font(13 * s); color = Self.ink
            case .note: font = Self.font(11.5 * s); color = Self.mid
            case .error: font = Self.font(12 * s, bold: true); color = Self.ink
            }
            text.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph], range: range)
        }
        transcript.attributedText = text
    }

    private func render() {
        restyleTranscript()
        transcript.layoutIfNeeded()
        let bottom = max(0, transcript.contentSize.height - transcript.bounds.height)
        transcript.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    // MARK: - Actions

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let value = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        textField.text = ""
        onSubmit?(value)
        return false
    }

    @objc private func typeTapped() { onTypeIntoPsion?() }
    @objc private func newChatTapped() { onNewChat?() }
    @objc private func keyTapped() { onChangeKey?() }
    @objc private func transcriptTapped() { onTranscriptTapped?() }
}
