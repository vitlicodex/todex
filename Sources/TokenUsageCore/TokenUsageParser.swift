import Foundation

public struct TokenUsageFileResult: Sendable {
    public var samples: [TokenUsageSample]
    public var issues: [TokenMonitorIssue]
}

public final class TokenUsageParser: @unchecked Sendable {
    private let isoFormatter: ISO8601DateFormatter
    private let maxStructuredJSONBytes: UInt64
    private let maxJSONLinesBytes: UInt64
    private let maxLineBytes: Int
    private let maxSamplesPerFile: Int
    private let maxTraversalDepth: Int

    public init(
        maxStructuredJSONBytes: UInt64 = 25 * 1024 * 1024,
        maxJSONLinesBytes: UInt64 = 512 * 1024 * 1024,
        maxLineBytes: Int = 2 * 1024 * 1024,
        maxSamplesPerFile: Int = 10_000,
        maxTraversalDepth: Int = 18
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter = formatter
        self.maxStructuredJSONBytes = maxStructuredJSONBytes
        self.maxJSONLinesBytes = maxJSONLinesBytes
        self.maxLineBytes = maxLineBytes
        self.maxSamplesPerFile = maxSamplesPerFile
        self.maxTraversalDepth = maxTraversalDepth
    }

    public func parse(url: URL) -> TokenUsageFileResult {
        let extensionName = url.pathExtension.lowercased()
        let size = sourceSize(url)
        if extensionName == "jsonl" || extensionName == "log" {
            if size > maxJSONLinesBytes {
                return TokenUsageFileResult(samples: [], issues: [.unreadableSource(url.path, "File is too large to parse safely.")])
            }
            do {
                return try parseJSONLinesOrLog(url: url, sourceURL: url, fallbackDate: sourceModifiedAt(url))
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                    return TokenUsageFileResult(samples: [], issues: [.permissionDenied(url.path)])
                }
                return TokenUsageFileResult(samples: [], issues: [.unreadableSource(url.path, error.localizedDescription)])
            }
        }

        if size > maxStructuredJSONBytes {
            return TokenUsageFileResult(samples: [], issues: [.unreadableSource(url.path, "Structured JSON file is too large to parse safely.")])
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return parse(data: data, sourceURL: url, fallbackDate: sourceModifiedAt(url))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                return TokenUsageFileResult(samples: [], issues: [.permissionDenied(url.path)])
            }
            return TokenUsageFileResult(samples: [], issues: [.unreadableSource(url.path, error.localizedDescription)])
        }
    }

    public func parse(data: Data, sourceURL: URL, fallbackDate: Date = Date()) -> TokenUsageFileResult {
        let extensionName = sourceURL.pathExtension.lowercased()
        if extensionName == "jsonl" || extensionName == "log" {
            return parseJSONLinesOrLog(data: data, sourceURL: sourceURL, fallbackDate: fallbackDate)
        }

        if let object = try? JSONSerialization.jsonObject(with: data) {
            let sourceID = StableHash.make(sourceURL.path)
            let samples = samples(from: object, sourceURL: sourceURL, sourceID: sourceID, fallbackDate: fallbackDate, location: "root")
            if samples.isEmpty {
                return TokenUsageFileResult(samples: [], issues: [.apiUsageFieldsUnavailable(sourceURL.path)])
            }
            return TokenUsageFileResult(samples: samples, issues: [])
        }

        return parseJSONLinesOrLog(data: data, sourceURL: sourceURL, fallbackDate: fallbackDate)
    }

    private func parseJSONLinesOrLog(url: URL, sourceURL: URL, fallbackDate: Date) throws -> TokenUsageFileResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var samples: [TokenUsageSample] = []
        var sawMalformedJSONLine = false
        var sawInvalidUTF8Line = false
        let sourceID = StableHash.make(sourceURL.path)
        let newline = Data([0x0A])
        let tokenCountNeedle = Data(#""token_count""#.utf8)
        let onlyTokenCountLines = sourceURL.path.contains("/.codex/sessions/")
        var pending = Data()
        var lineNumber = 0

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let range = pending.firstRange(of: newline) {
                guard samples.count < maxSamplesPerFile else {
                    return TokenUsageFileResult(samples: samples, issues: [])
                }
                let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
                pending.removeSubrange(pending.startIndex..<range.upperBound)
                lineNumber += 1
                processLineData(
                    lineData,
                    lineNumber: lineNumber,
                    onlyTokenCountLines: onlyTokenCountLines,
                    tokenCountNeedle: tokenCountNeedle,
                    sourceURL: sourceURL,
                    sourceID: sourceID,
                    fallbackDate: fallbackDate,
                    samples: &samples,
                    sawMalformedJSONLine: &sawMalformedJSONLine,
                    sawInvalidUTF8Line: &sawInvalidUTF8Line
                )
            }
            if pending.count > maxLineBytes {
                sawMalformedJSONLine = true
                pending.removeAll(keepingCapacity: true)
            }
        }

        if !pending.isEmpty && samples.count < maxSamplesPerFile {
            lineNumber += 1
            processLineData(
                pending,
                lineNumber: lineNumber,
                onlyTokenCountLines: onlyTokenCountLines,
                tokenCountNeedle: tokenCountNeedle,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                samples: &samples,
                sawMalformedJSONLine: &sawMalformedJSONLine,
                sawInvalidUTF8Line: &sawInvalidUTF8Line
            )
        }

        var issues: [TokenMonitorIssue] = []
        if samples.isEmpty {
            if sawInvalidUTF8Line {
                issues.append(.unreadableSource(sourceURL.path, "File contains invalid UTF-8."))
            } else {
                issues.append(sawMalformedJSONLine ? .invalidJSON(sourceURL.path) : .apiUsageFieldsUnavailable(sourceURL.path))
            }
        }
        return TokenUsageFileResult(samples: samples, issues: issues)
    }

    private func parseJSONLinesOrLog(data: Data, sourceURL: URL, fallbackDate: Date) -> TokenUsageFileResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return TokenUsageFileResult(samples: [], issues: [.unreadableSource(sourceURL.path, "File is not valid UTF-8.")])
        }

        var samples: [TokenUsageSample] = []
        var sawMalformedJSONLine = false
        let sourceID = StableHash.make(sourceURL.path)

        for (index, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            guard samples.count < maxSamplesPerFile else { break }
            processLine(
                String(rawLine),
                lineNumber: index + 1,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                samples: &samples,
                sawMalformedJSONLine: &sawMalformedJSONLine
            )
        }

        var issues: [TokenMonitorIssue] = []
        if samples.isEmpty {
            issues.append(sawMalformedJSONLine ? .invalidJSON(sourceURL.path) : .apiUsageFieldsUnavailable(sourceURL.path))
        }
        return TokenUsageFileResult(samples: samples, issues: issues)
    }

    private func processLineData(
        _ lineData: Data,
        lineNumber: Int,
        onlyTokenCountLines: Bool,
        tokenCountNeedle: Data,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        samples: inout [TokenUsageSample],
        sawMalformedJSONLine: inout Bool,
        sawInvalidUTF8Line: inout Bool
    ) {
        if onlyTokenCountLines && lineData.range(of: tokenCountNeedle) == nil {
            return
        }

        guard let line = String(data: lineData, encoding: .utf8) else {
            sawInvalidUTF8Line = true
            return
        }

        processLine(
            line,
            lineNumber: lineNumber,
            sourceURL: sourceURL,
            sourceID: sourceID,
            fallbackDate: fallbackDate,
            samples: &samples,
            sawMalformedJSONLine: &sawMalformedJSONLine
        )
    }

    private func processLine(
        _ rawLine: String,
        lineNumber: Int,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        samples: inout [TokenUsageSample],
        sawMalformedJSONLine: inout Bool
    ) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if line.first == "{" || line.first == "[" {
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                let location = "line:\(lineNumber)"
                let extracted = self.samples(
                    from: object,
                    sourceURL: sourceURL,
                    sourceID: sourceID,
                    fallbackDate: fallbackDate,
                    location: location
                )
                samples.append(contentsOf: extracted)
                return
            }
            sawMalformedJSONLine = true
        }

        if let sample = regexSample(from: line, sourceURL: sourceURL, sourceID: sourceID, fallbackDate: fallbackDate, lineNumber: lineNumber) {
            samples.append(sample)
        }
    }

    private func samples(
        from object: Any,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String
    ) -> [TokenUsageSample] {
        var output: [TokenUsageSample] = []
        collectSamples(
            from: object,
            sourceURL: sourceURL,
            sourceID: sourceID,
            fallbackDate: fallbackDate,
            location: location,
            inheritedTimestamp: nil,
            depth: 0,
            output: &output
        )
        var seen = Set<String>()
        return output.filter { sample in
            let semanticID = "\(sample.sourcePath)|\(sample.timestamp.timeIntervalSince1970)|\(sample.inputTokens)|\(sample.outputTokens)|\(sample.totalTokens)|\(sample.mode.rawValue)"
            guard !seen.contains(semanticID) else { return false }
            seen.insert(semanticID)
            return true
        }
    }

    private func collectSamples(
        from object: Any,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String,
        inheritedTimestamp: Date?,
        depth: Int,
        output: inout [TokenUsageSample]
    ) {
        guard output.count < maxSamplesPerFile, depth <= maxTraversalDepth else {
            return
        }

        if let dictionary = object as? [String: Any] {
            let contextualTimestamp = timestamp(from: dictionary) ?? inheritedTimestamp
            if let codexSample = codexTokenCountSample(
                from: dictionary,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                location: location,
                inheritedTimestamp: contextualTimestamp
            ) {
                output.append(codexSample)
                return
            }

            guard output.count < maxSamplesPerFile else { return }
            if let realSample = realUsageSample(
                from: dictionary,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                location: location,
                inheritedTimestamp: contextualTimestamp
            ) {
                output.append(realSample)
            } else if let estimatedSample = estimatedSample(
                from: dictionary,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                location: location,
                inheritedTimestamp: contextualTimestamp
            ) {
                output.append(estimatedSample)
            }

            for (key, value) in dictionary {
                guard output.count < maxSamplesPerFile else { break }
                guard shouldTraverse(key: key) else { continue }
                collectSamples(
                    from: value,
                    sourceURL: sourceURL,
                    sourceID: sourceID,
                    fallbackDate: fallbackDate,
                    location: "\(location).\(key)",
                    inheritedTimestamp: contextualTimestamp,
                    depth: depth + 1,
                    output: &output
                )
            }
            return
        }

        if let array = object as? [Any] {
            for (index, value) in array.enumerated() {
                guard output.count < maxSamplesPerFile else { break }
                collectSamples(
                    from: value,
                    sourceURL: sourceURL,
                    sourceID: sourceID,
                    fallbackDate: fallbackDate,
                    location: "\(location)[\(index)]",
                    inheritedTimestamp: inheritedTimestamp,
                    depth: depth + 1,
                    output: &output
                )
            }
        }
    }

    private func shouldTraverse(key: String) -> Bool {
        let lowered = key.lowercased()
        let blocked = ["content", "message", "messages", "prompt", "text", "input", "output"]
        if blocked.contains(lowered) {
            return false
        }

        // Codex session logs expose cumulative totals here. Counting those as
        // per-prompt samples would double count; use last_token_usage instead.
        return lowered != "total_token_usage"
    }

    private func codexTokenCountSample(
        from dictionary: [String: Any],
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String,
        inheritedTimestamp: Date?
    ) -> TokenUsageSample? {
        let payload = dictionary["payload"] as? [String: Any]
        let event = payload ?? dictionary
        guard stringValue(in: event, keys: ["type"]) == "token_count" else {
            return nil
        }

        let info = event["info"] as? [String: Any] ?? event
        guard let usage = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        let inputTokens = intValue(in: usage, keys: ["input_tokens", "inputTokens"]) ?? 0
        let outputTokens = intValue(in: usage, keys: ["output_tokens", "outputTokens"]) ?? 0
        let total = intValue(in: usage, keys: ["total_tokens", "totalTokens"]) ?? (inputTokens + outputTokens)
        guard total > 0 else { return nil }

        let timestamp = timestamp(from: dictionary)
            ?? timestamp(from: event)
            ?? inheritedTimestamp
            ?? fallbackDate
        let stableText = "\(sourceURL.path)|\(location)|codex-token-count|\(timestamp.timeIntervalSince1970)|\(inputTokens)|\(outputTokens)|\(total)"

        return TokenUsageSample(
            id: StableHash.make(stableText),
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: total,
            mode: .real,
            sourceID: sourceID,
            sourcePath: sourceURL.path
        )
    }

    private func realUsageSample(
        from dictionary: [String: Any],
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String,
        inheritedTimestamp: Date?
    ) -> TokenUsageSample? {
        let inputTokens = intValue(in: dictionary, keys: [
            "input_tokens",
            "prompt_tokens",
            "tokens_in",
            "inputTokens",
            "promptTokens"
        ]) ?? 0
        let outputTokens = intValue(in: dictionary, keys: [
            "output_tokens",
            "completion_tokens",
            "tokens_out",
            "outputTokens",
            "completionTokens"
        ]) ?? 0
        let explicitTotal = intValue(in: dictionary, keys: [
            "total_tokens",
            "totalTokens"
        ])

        let total = explicitTotal ?? (inputTokens + outputTokens)
        guard total > 0, inputTokens > 0 || outputTokens > 0 || explicitTotal != nil else {
            return nil
        }

        let timestamp = timestamp(from: dictionary) ?? inheritedTimestamp ?? fallbackDate
        let stableText = "\(sourceURL.path)|\(timestamp.timeIntervalSince1970)|\(inputTokens)|\(outputTokens)|\(total)"
        return TokenUsageSample(
            id: StableHash.make(stableText),
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: total,
            mode: .real,
            sourceID: sourceID,
            sourcePath: sourceURL.path
        )
    }

    private func estimatedSample(
        from dictionary: [String: Any],
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String,
        inheritedTimestamp: Date?
    ) -> TokenUsageSample? {
        guard looksLikeUserPromptEvent(dictionary) else { return nil }
        guard let text = promptLikeText(from: dictionary), !text.isEmpty else { return nil }

        let estimatedTokens = max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
        let timestamp = timestamp(from: dictionary) ?? inheritedTimestamp ?? fallbackDate
        let stableText = "\(sourceURL.path)|\(timestamp.timeIntervalSince1970)|estimated|\(estimatedTokens)"

        return TokenUsageSample(
            id: StableHash.make(stableText),
            timestamp: timestamp,
            inputTokens: estimatedTokens,
            outputTokens: 0,
            totalTokens: estimatedTokens,
            mode: .estimated,
            sourceID: sourceID,
            sourcePath: sourceURL.path
        )
    }

    private func looksLikeUserPromptEvent(_ dictionary: [String: Any]) -> Bool {
        let role = stringValue(in: dictionary, keys: ["role", "author", "speaker"])?.lowercased()
        if role == "user" {
            return true
        }

        let type = stringValue(in: dictionary, keys: ["type", "event", "kind"])?.lowercased() ?? ""
        return type.contains("user") || type.contains("prompt") || type.contains("input_message")
    }

    private func promptLikeText(from dictionary: [String: Any]) -> String? {
        for key in ["prompt", "content", "text", "input"] {
            if let value = dictionary[key] as? String {
                return value
            }
        }

        if let message = dictionary["message"] as? [String: Any] {
            return promptLikeText(from: message)
        }

        return nil
    }

    private func regexSample(
        from line: String,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        lineNumber: Int
    ) -> TokenUsageSample? {
        let input = regexInt(line, pattern: #"(?:input|prompt)[_\s-]*tokens?\s*[:=]\s*([0-9]+)"#) ?? 0
        let output = regexInt(line, pattern: #"(?:output|completion)[_\s-]*tokens?\s*[:=]\s*([0-9]+)"#) ?? 0
        let total = regexInt(line, pattern: #"total[_\s-]*tokens?\s*[:=]\s*([0-9]+)"#) ?? (input + output)

        guard total > 0 else { return nil }

        let id = StableHash.make("\(sourceURL.path)|line:\(lineNumber)|\(input)|\(output)|\(total)")
        return TokenUsageSample(
            id: id,
            timestamp: fallbackDate,
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            mode: .real,
            sourceID: sourceID,
            sourcePath: sourceURL.path
        )
    }

    private func regexInt(_ line: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[valueRange])
    }

    private func intValue(in dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] {
                return intValue(value)
            }
        }
        return nil
    }

    private func intValue(_ value: Any) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }
        return nil
    }

    private func timestamp(from dictionary: [String: Any]) -> Date? {
        for key in ["timestamp", "created_at", "createdAt", "time", "date"] {
            guard let value = dictionary[key] else { continue }
            if let date = value as? Date {
                return date
            }
            if let string = value as? String {
                if let date = isoFormatter.date(from: string) {
                    return date
                }

                let fallbackFormatter = ISO8601DateFormatter()
                if let date = fallbackFormatter.date(from: string) {
                    return date
                }
            }
            if let number = value as? NSNumber {
                let raw = number.doubleValue
                if raw > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: raw / 1_000)
                }
                if raw > 1_000_000_000 {
                    return Date(timeIntervalSince1970: raw)
                }
            }
        }
        return nil
    }

    private func sourceModifiedAt(_ url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? Date()
    }

    private func sourceSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }
}
