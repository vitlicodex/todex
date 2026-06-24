import Foundation

public struct TokenUsageFileResult: Sendable {
    public var samples: [TokenUsageSample]
    public var issues: [TokenMonitorIssue]
}

private struct ProjectMetadata {
    var id: String
    var name: String
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
        let turnContextNeedle = Data(#""turn_context""#.utf8)
        let sessionMetaNeedle = Data(#""session_meta""#.utf8)
        let environmentContextNeedle = Data(#""environment_context""#.utf8)
        let onlyTokenCountLines = sourceURL.path.contains("/.codex/sessions/")
        var currentProject: ProjectMetadata?
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
                    turnContextNeedle: turnContextNeedle,
                    sessionMetaNeedle: sessionMetaNeedle,
                    environmentContextNeedle: environmentContextNeedle,
                    sourceURL: sourceURL,
                    sourceID: sourceID,
                    fallbackDate: fallbackDate,
                    currentProject: &currentProject,
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
                turnContextNeedle: turnContextNeedle,
                sessionMetaNeedle: sessionMetaNeedle,
                environmentContextNeedle: environmentContextNeedle,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                currentProject: &currentProject,
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
        let onlyTokenCountLines = sourceURL.path.contains("/.codex/sessions/")
        var currentProject: ProjectMetadata?

        for (index, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            guard samples.count < maxSamplesPerFile else { break }
            processLine(
                String(rawLine),
                lineNumber: index + 1,
                onlyTokenCountLines: onlyTokenCountLines,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                currentProject: &currentProject,
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
        turnContextNeedle: Data,
        sessionMetaNeedle: Data,
        environmentContextNeedle: Data,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        currentProject: inout ProjectMetadata?,
        samples: inout [TokenUsageSample],
        sawMalformedJSONLine: inout Bool,
        sawInvalidUTF8Line: inout Bool
    ) {
        if onlyTokenCountLines {
            let hasProjectMetadata = lineData.range(of: turnContextNeedle) != nil
                || lineData.range(of: sessionMetaNeedle) != nil
                || lineData.range(of: environmentContextNeedle) != nil
            let hasTokenCount = lineData.range(of: tokenCountNeedle) != nil
            guard hasProjectMetadata || hasTokenCount else {
                return
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                sawInvalidUTF8Line = true
                return
            }
            if hasProjectMetadata {
                updateProjectMetadata(from: line, currentProject: &currentProject)
                return
            }
            processLine(
                line,
                lineNumber: lineNumber,
                onlyTokenCountLines: true,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                currentProject: &currentProject,
                samples: &samples,
                sawMalformedJSONLine: &sawMalformedJSONLine
            )
            return
        }

        guard let line = String(data: lineData, encoding: .utf8) else {
            sawInvalidUTF8Line = true
            return
        }

        processLine(
            line,
            lineNumber: lineNumber,
            onlyTokenCountLines: onlyTokenCountLines,
            sourceURL: sourceURL,
            sourceID: sourceID,
            fallbackDate: fallbackDate,
            currentProject: &currentProject,
            samples: &samples,
            sawMalformedJSONLine: &sawMalformedJSONLine
        )
    }

    private func processLine(
        _ rawLine: String,
        lineNumber: Int,
        onlyTokenCountLines: Bool = false,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        currentProject: inout ProjectMetadata?,
        samples: inout [TokenUsageSample],
        sawMalformedJSONLine: inout Bool
    ) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if line.first == "{" || line.first == "[" {
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                if onlyTokenCountLines,
                   let dictionary = object as? [String: Any],
                   dictionaryContainsProjectMetadata(dictionary) {
                    currentProject = projectMetadata(from: dictionary) ?? currentProject
                    return
                }
                let location = "line:\(lineNumber)"
                let extracted = self.samples(
                    from: object,
                    sourceURL: sourceURL,
                    sourceID: sourceID,
                    fallbackDate: fallbackDate,
                    location: location,
                    currentProject: currentProject
                )
                samples.append(contentsOf: extracted)
                return
            }
            sawMalformedJSONLine = true
        }

        if let sample = regexSample(
            from: line,
            sourceURL: sourceURL,
            sourceID: sourceID,
            fallbackDate: fallbackDate,
            lineNumber: lineNumber,
            currentProject: currentProject
        ) {
            samples.append(sample)
        }
    }

    private func samples(
        from object: Any,
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String,
        currentProject: ProjectMetadata? = nil
    ) -> [TokenUsageSample] {
        var output: [TokenUsageSample] = []
        collectSamples(
            from: object,
            sourceURL: sourceURL,
            sourceID: sourceID,
            fallbackDate: fallbackDate,
            location: location,
            inheritedTimestamp: nil,
            currentProject: currentProject,
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
        currentProject: ProjectMetadata?,
        depth: Int,
        output: inout [TokenUsageSample]
    ) {
        guard output.count < maxSamplesPerFile, depth <= maxTraversalDepth else {
            return
        }

        if let dictionary = object as? [String: Any] {
            let contextualTimestamp = timestamp(from: dictionary) ?? inheritedTimestamp
            let contextualProject = projectMetadata(from: dictionary) ?? currentProject
            if let codexSample = codexTokenCountSample(
                from: dictionary,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                location: location,
                inheritedTimestamp: contextualTimestamp,
                currentProject: contextualProject
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
                inheritedTimestamp: contextualTimestamp,
                currentProject: contextualProject
            ) {
                output.append(realSample)
            } else if let estimatedSample = estimatedSample(
                from: dictionary,
                sourceURL: sourceURL,
                sourceID: sourceID,
                fallbackDate: fallbackDate,
                location: location,
                inheritedTimestamp: contextualTimestamp,
                currentProject: contextualProject
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
                    currentProject: contextualProject,
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
                    currentProject: currentProject,
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
        inheritedTimestamp: Date?,
        currentProject: ProjectMetadata?
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
            sourcePath: sourceURL.path,
            projectID: currentProject?.id,
            projectName: currentProject?.name
        )
    }

    private func realUsageSample(
        from dictionary: [String: Any],
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String,
        inheritedTimestamp: Date?,
        currentProject: ProjectMetadata?
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
            sourcePath: sourceURL.path,
            projectID: currentProject?.id,
            projectName: currentProject?.name
        )
    }

    private func estimatedSample(
        from dictionary: [String: Any],
        sourceURL: URL,
        sourceID: String,
        fallbackDate: Date,
        location: String,
        inheritedTimestamp: Date?,
        currentProject: ProjectMetadata?
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
            sourcePath: sourceURL.path,
            projectID: currentProject?.id,
            projectName: currentProject?.name
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
        lineNumber: Int,
        currentProject: ProjectMetadata?
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
            sourcePath: sourceURL.path,
            projectID: currentProject?.id,
            projectName: currentProject?.name
        )
    }

    private func updateProjectMetadata(from line: String, currentProject: inout ProjectMetadata?) {
        guard let data = line.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        currentProject = projectMetadata(from: dictionary) ?? currentProject
    }

    private func dictionaryContainsProjectMetadata(_ dictionary: [String: Any]) -> Bool {
        let metadataTypes = ["turn_context", "session_meta", "environment_context"]
        if let type = stringValue(in: dictionary, keys: ["type"]),
           metadataTypes.contains(type) {
            return true
        }
        if let payload = dictionary["payload"] as? [String: Any],
           let type = stringValue(in: payload, keys: ["type"]),
           metadataTypes.contains(type) {
            return true
        }
        return false
    }

    private func projectMetadata(from dictionary: [String: Any]) -> ProjectMetadata? {
        let candidates = projectPathCandidates(from: dictionary)
        for candidate in candidates {
            let normalized = normalizedProjectPath(candidate)
            guard !normalized.isEmpty else { continue }
            let name = projectName(from: normalized)
            guard !name.isEmpty else { continue }
            return ProjectMetadata(id: StableHash.make(normalized), name: name)
        }
        return nil
    }

    private func projectPathCandidates(from dictionary: [String: Any]) -> [String] {
        var output: [String] = []
        collectProjectPathCandidates(from: dictionary, output: &output, depth: 0)
        return output
    }

    private func collectProjectPathCandidates(from object: Any, output: inout [String], depth: Int) {
        guard depth <= 4, output.count < 12 else { return }
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let lowered = key.lowercased()
                if ["cwd", "workdir", "working_directory", "current_working_directory", "workspace", "workspace_root", "workspace_directory", "project_path"].contains(lowered),
                   let string = value as? String {
                    output.append(string)
                } else if ["workspace_roots", "workspace_folders", "roots"].contains(lowered),
                          let array = value as? [Any] {
                    for item in array {
                        if let string = item as? String {
                            output.append(string)
                        } else {
                            collectProjectPathCandidates(from: item, output: &output, depth: depth + 1)
                        }
                    }
                } else if lowered == "payload" || lowered == "turn_context" || lowered == "context" || lowered == "environment_context" {
                    collectProjectPathCandidates(from: value, output: &output, depth: depth + 1)
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                collectProjectPathCandidates(from: item, output: &output, depth: depth + 1)
            }
        }
    }

    private func normalizedProjectPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func projectName(from path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty && last != "/" {
            return last
        }
        return path
            .split(separator: "/")
            .last
            .map(String.init) ?? "Unknown Project"
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
