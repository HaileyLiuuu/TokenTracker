import Foundation

public enum LocalTokenScanner {
    public static func codexTokens(in roots: [URL], since cutoff: Date) -> Int {
        var total = 0
        for file in jsonlFiles(in: roots) {
            forEachLine(in: file) { line in
                guard
                    let event = try? JSONDecoder().decode(CodexTokenEvent.self, from: line),
                    event.type == "event_msg",
                    event.payload.type == "token_count",
                    let timestamp = parseTimestamp(event.timestamp),
                    timestamp >= cutoff
                else { return }
                total += max(event.payload.info?.lastTokenUsage?.totalTokens ?? 0, 0)
            }
        }
        return total
    }

    public static func claudeTokens(in roots: [URL], since cutoff: Date) -> Int {
        var total = 0
        var seenMessages = Set<String>()
        for file in jsonlFiles(in: roots) {
            forEachLine(in: file) { line in
                guard
                    let event = try? JSONDecoder().decode(ClaudeTokenEvent.self, from: line),
                    event.type == "assistant",
                    let timestamp = parseTimestamp(event.timestamp),
                    timestamp >= cutoff,
                    let usage = event.message.usage
                else { return }

                let identity = event.message.id ?? "\(event.timestamp)-\(usage.total)"
                guard seenMessages.insert(identity).inserted else { return }
                total += max(usage.total, 0)
            }
        }
        return total
    }
}

private struct CodexTokenEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let info: Info?
    }

    struct Info: Decodable {
        let lastTokenUsage: TokenUsage?

        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
        }
    }

    struct TokenUsage: Decodable {
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
        }
    }
}

private struct ClaudeTokenEvent: Decodable {
    let timestamp: String
    let type: String
    let message: Message

    struct Message: Decodable {
        let id: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        var total: Int {
            (inputTokens ?? 0)
                + (outputTokens ?? 0)
                + (cacheReadInputTokens ?? 0)
                + (cacheCreationInputTokens ?? 0)
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }
}

private func jsonlFiles(in roots: [URL]) -> [URL] {
    let fileManager = FileManager.default
    var files: [URL] = []
    for root in roots {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
        if !isDirectory.boolValue {
            if root.pathExtension == "jsonl" { files.append(root) }
            continue
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
    }
    return files
}

private func forEachLine(in file: URL, body: (Data) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return }
    defer { try? handle.close() }

    // Session records can contain very large prompt fields. Keep memory bounded and
    // discard oversized records; token-count records are small structured events.
    let chunkSize = 64 * 1_024
    let maximumLineSize = 8 * 1_024 * 1_024
    var buffer = Data()
    var discardingOversizedLine = false

    while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let remainder = chunk[start...]
            if let newline = remainder.firstIndex(of: 0x0A) {
                if !discardingOversizedLine {
                    let fragment = chunk[start..<newline]
                    if buffer.count + fragment.count <= maximumLineSize {
                        buffer.append(contentsOf: fragment)
                        if !buffer.isEmpty { body(buffer) }
                    }
                }
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
                start = chunk.index(after: newline)
            } else {
                if !discardingOversizedLine {
                    let fragment = chunk[start..<chunk.endIndex]
                    if buffer.count + fragment.count <= maximumLineSize {
                        buffer.append(contentsOf: fragment)
                    } else {
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                    }
                }
                break
            }
        }
    }

    if !discardingOversizedLine, !buffer.isEmpty { body(buffer) }
}

private func parseTimestamp(_ value: String) -> Date? {
    parseISO8601Timestamp(value)
}
