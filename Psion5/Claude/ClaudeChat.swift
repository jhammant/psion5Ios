import Foundation
import os

private let log = Logger(subsystem: "io.hammant.psion5", category: "claude")

/// A conversation with Claude over the Messages API. There's no official
/// Anthropic SDK for Swift, so this speaks the HTTP API directly and reads the
/// streamed reply as server-sent events.
@MainActor
final class ClaudeChat {
    static let model = "claude-opus-5-5"
    static let modelName = "Opus 5.5"

    enum Event {
        case text(String)
        case finished(cutShort: Bool)
        case failed(String)
    }

    /// The text of the last complete reply, for typing into the Psion.
    private(set) var lastAnswer: String?
    var isBusy: Bool { task != nil }

    /// The conversation as sent to the API. Assistant turns keep every
    /// content block exactly as it arrived (including thinking blocks and
    /// their signatures), because the API checks they come back unchanged.
    private var messages: [[String: Any]] = []
    private var task: Task<Void, Never>?
    /// Bumped by reset(), so a reply still streaming for an earlier
    /// conversation is ignored instead of landing in the new one.
    private var generation = 0

    private static let systemPrompt = """
        You are Claude, running as an app on a Psion Series 5mx, a 1999 handheld computer, emulated on \
        an iPhone with a folding keyboard. Its screen is a small 640x240 greyscale LCD that shows plain \
        text only, so don't use Markdown, tables, headings or emoji; use short paragraphs and lines \
        starting with "- " for lists. Keep answers brief unless asked for more: a few lines is ideal. \
        The user can type your answer straight into a Psion app such as Word or Jotter, and the Psion \
        keyboard only makes plain ASCII characters plus a few symbols like £ and €, so prefer straight \
        quotes and plain hyphens.
        """

    private static var endpoint: URL {
        #if DEBUG
        // Lets tests point the app at scripts/mock-claude.py.
        if let override = ProcessInfo.processInfo.environment["CLAUDE_API_URL"], let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://api.anthropic.com/v1/messages")!
    }

    func send(_ prompt: String, apiKey: String, onEvent: @escaping (Event) -> Void) {
        guard task == nil else { return }
        messages.append(["role": "user", "content": prompt])
        let request: URLRequest
        do {
            request = try makeRequest(apiKey: apiKey)
        } catch {
            messages.removeLast()
            onEvent(.failed("Couldn't build the request: \(error.localizedDescription)"))
            return
        }

        let generation = self.generation
        task = Task { [weak self] in
            let outcome: Event
            do {
                let reply = try await Self.stream(request, onText: { text in
                    if self?.generation == generation { onEvent(.text(text)) }
                })
                guard let self, self.generation == generation else { return }
                outcome = self.finish(reply)
            } catch is CancellationError {
                outcome = .failed("Stopped.")
            } catch let error as URLError where error.code == .cancelled {
                outcome = .failed("Stopped.")
            } catch let error as ClaudeError {
                outcome = .failed(error.message)
            } catch {
                outcome = .failed("Couldn't reach Claude: \(error.localizedDescription)")
            }
            guard let self, self.generation == generation else { return }
            if case .failed = outcome, self.messages.last?["role"] as? String == "user" {
                // Drop the unanswered question so the history stays a clean
                // user/assistant alternation the API will accept next time.
                self.messages.removeLast()
            }
            self.task = nil
            onEvent(outcome)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        cancel()
        task = nil
        generation += 1
        messages.removeAll()
        lastAnswer = nil
    }

    // MARK: - Request

    private func makeRequest(apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // If a safety classifier declines, the API retries on Anthropic's
        // recommended fallback model instead of returning a refusal.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 64000,
            "stream": true,
            "system": Self.systemPrompt,
            "messages": messages,
            "fallbacks": "default",
            // Chat answers don't need deep thinking; low effort keeps them quick.
            "output_config": ["effort": "low"],
            "cache_control": ["type": "ephemeral"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Streaming

    private struct Reply {
        var blocks: [Int: [String: Any]] = [:]
        var stopReason: String?
    }

    struct ClaudeError: Error {
        let message: String
    }

    /// Reads the server-sent events of one streamed reply. Every `data:` line
    /// carries one complete JSON event, so lines are parsed independently.
    private static func stream(_ request: URLRequest, onText: @escaping (String) -> Void) async throws -> Reply {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw ClaudeError(message: describe(status: status, body: body))
        }

        var reply = Reply()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { continue }
                reply.blocks[index] = block
                if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                    onText(text)
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any],
                      var block = reply.blocks[index] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + text
                    onText(text)
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                default:
                    break
                }
                reply.blocks[index] = block
            case "message_delta":
                if let stop = (event["delta"] as? [String: Any])?["stop_reason"] as? String {
                    reply.stopReason = stop
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw ClaudeError(message: describe(errorType: error?["type"] as? String, message: error?["message"] as? String))
            default:
                break
            }
        }
        return reply
    }

    /// Turns a finished stream into a conversation turn, or an error.
    private func finish(_ reply: Reply) -> Event {
        if reply.stopReason == "refusal" {
            return .failed("Claude declined to answer that one.")
        }
        let blocks = Self.blocksToEcho(reply.blocks.sorted { $0.key < $1.key }.map(\.value))
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else {
            return .failed("No answer came back. Try asking again.")
        }
        messages.append(["role": "assistant", "content": blocks])
        lastAnswer = text
        return .finished(cutShort: reply.stopReason == "max_tokens")
    }

    /// The reply's content blocks as they should be sent back next turn. If a
    /// fallback model took over mid-reply, only text survives from before the
    /// switch (the fallback marker itself is dropped). Empty text blocks are
    /// dropped because the API rejects them.
    private static func blocksToEcho(_ blocks: [[String: Any]]) -> [[String: Any]] {
        let lastFallback = blocks.lastIndex { $0["type"] as? String == "fallback" } ?? -1
        return blocks.enumerated().compactMap { index, block in
            let type = block["type"] as? String
            if type == "fallback" { return nil }
            if index < lastFallback && type != "text" { return nil }
            if type == "text", (block["text"] as? String ?? "").isEmpty { return nil }
            return block
        }
    }

    // MARK: - Errors

    private static func describe(status: Int, body: String) -> String {
        let error = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String
        log.error("HTTP \(status, privacy: .public): \(message ?? body, privacy: .public)")
        switch status {
        case 401: return "Your API key was rejected. Press Ctrl+K to enter a new one."
        case 403: return "This API key can't use Claude: \(message ?? "permission denied")."
        case 429: return "Too many requests right now. Try again in a moment."
        case 500...599: return describe(errorType: error?["type"] as? String, message: message)
        default: return "Claude rejected the request (\(status)): \(message ?? "unknown error")."
        }
    }

    private static func describe(errorType: String?, message: String?) -> String {
        switch errorType {
        case "overloaded_error": return "Claude is busy right now. Try again in a moment."
        case "rate_limit_error": return "Too many requests right now. Try again in a moment."
        default: return "Claude hit an error: \(message ?? errorType ?? "unknown")."
        }
    }
}
