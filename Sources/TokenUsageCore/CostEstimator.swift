import Foundation

public struct TokenPricingProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var inputPerMillionUSD: Double
    public var cachedInputPerMillionUSD: Double
    public var outputPerMillionUSD: Double
    public var reasoningPerMillionUSD: Double
    public var multiplier: Double
    public var notes: String?

    public init(
        id: String? = nil,
        name: String,
        inputPerMillionUSD: Double,
        cachedInputPerMillionUSD: Double,
        outputPerMillionUSD: Double,
        reasoningPerMillionUSD: Double = 0,
        multiplier: Double = 1,
        notes: String? = nil
    ) {
        self.id = id ?? String(StableHash.make(name).prefix(12))
        self.name = name
        self.inputPerMillionUSD = inputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.reasoningPerMillionUSD = reasoningPerMillionUSD
        self.multiplier = multiplier
        self.notes = notes
    }

    public static let defaultLocalEstimate = TokenPricingProfile(
        id: "local-default",
        name: "Default Local Codex Estimate",
        inputPerMillionUSD: 5,
        cachedInputPerMillionUSD: 0.5,
        outputPerMillionUSD: 20,
        reasoningPerMillionUSD: 0,
        multiplier: 1,
        notes: "Editable estimate. This is not an actual OpenAI bill."
    )

    public static let defaultProfiles: [TokenPricingProfile] = [
        .defaultLocalEstimate,
        TokenPricingProfile(
            id: "local-priority",
            name: "Priority Local Codex Estimate",
            inputPerMillionUSD: 5,
            cachedInputPerMillionUSD: 0.5,
            outputPerMillionUSD: 20,
            reasoningPerMillionUSD: 0,
            multiplier: 2.5,
            notes: "Editable estimate with multiplier for higher-cost modes."
        ),
        TokenPricingProfile(
            id: "local-low-cost",
            name: "Low-Cost Local Estimate",
            inputPerMillionUSD: 1,
            cachedInputPerMillionUSD: 0.1,
            outputPerMillionUSD: 4,
            reasoningPerMillionUSD: 0,
            multiplier: 1,
            notes: "Editable estimate for lower-cost model assumptions."
        )
    ]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case inputPerMillionUSD
        case cachedInputPerMillionUSD
        case outputPerMillionUSD
        case reasoningPerMillionUSD
        case multiplier
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? String(StableHash.make(name).prefix(12))
        inputPerMillionUSD = try container.decode(Double.self, forKey: .inputPerMillionUSD)
        cachedInputPerMillionUSD = try container.decode(Double.self, forKey: .cachedInputPerMillionUSD)
        outputPerMillionUSD = try container.decode(Double.self, forKey: .outputPerMillionUSD)
        reasoningPerMillionUSD = try container.decodeIfPresent(Double.self, forKey: .reasoningPerMillionUSD) ?? 0
        multiplier = try container.decodeIfPresent(Double.self, forKey: .multiplier) ?? 1
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public var validationIssues: [TokenPricingProfileValidationIssue] {
        var issues: [TokenPricingProfileValidationIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if inputPerMillionUSD < 0 {
            issues.append(.negativeInputPrice)
        }
        if cachedInputPerMillionUSD < 0 {
            issues.append(.negativeCachedInputPrice)
        }
        if outputPerMillionUSD < 0 {
            issues.append(.negativeOutputPrice)
        }
        if reasoningPerMillionUSD < 0 {
            issues.append(.negativeReasoningPrice)
        }
        if multiplier <= 0 {
            issues.append(.nonPositiveMultiplier)
        }
        return issues
    }

    public var isValid: Bool {
        validationIssues.isEmpty
    }

    public func validated() throws -> TokenPricingProfile {
        let issues = validationIssues
        if issues.isEmpty {
            return self
        }
        throw TokenPricingProfileValidationError(issues: issues)
    }

    public static func defaultProfile(id: String) -> TokenPricingProfile? {
        defaultProfiles.first { $0.id == id }
    }
}

public enum TokenPricingProfileValidationIssue: String, Codable, Equatable, Sendable {
    case emptyName
    case negativeInputPrice
    case negativeCachedInputPrice
    case negativeOutputPrice
    case negativeReasoningPrice
    case nonPositiveMultiplier

    public var message: String {
        switch self {
        case .emptyName:
            return "Profile name cannot be empty."
        case .negativeInputPrice:
            return "Input price cannot be negative."
        case .negativeCachedInputPrice:
            return "Cached input price cannot be negative."
        case .negativeOutputPrice:
            return "Output price cannot be negative."
        case .negativeReasoningPrice:
            return "Reasoning price cannot be negative."
        case .nonPositiveMultiplier:
            return "Multiplier must be positive."
        }
    }
}

public struct TokenPricingProfileValidationError: Error, Equatable, Sendable, LocalizedError {
    public var issues: [TokenPricingProfileValidationIssue]

    public init(issues: [TokenPricingProfileValidationIssue]) {
        self.issues = issues
    }

    public var errorDescription: String? {
        issues.map(\.message).joined(separator: "\n")
    }
}

public struct TokenCostEstimate: Codable, Equatable, Sendable {
    public var inputCostUSD: Double
    public var cachedInputCostUSD: Double
    public var outputCostUSD: Double
    public var reasoningCostUSD: Double
    public var totalCostUSD: Double
    public var pricingProfileName: String
    public var isEstimated: Bool

    public init(
        inputCostUSD: Double,
        cachedInputCostUSD: Double,
        outputCostUSD: Double,
        reasoningCostUSD: Double,
        totalCostUSD: Double,
        pricingProfileName: String,
        isEstimated: Bool = true
    ) {
        self.inputCostUSD = inputCostUSD
        self.cachedInputCostUSD = cachedInputCostUSD
        self.outputCostUSD = outputCostUSD
        self.reasoningCostUSD = reasoningCostUSD
        self.totalCostUSD = totalCostUSD
        self.pricingProfileName = pricingProfileName
        self.isEstimated = isEstimated
    }
}

public typealias EstimatedTokenCost = TokenCostEstimate

public enum CostEstimator {
    public static func estimate(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        profile: TokenPricingProfile
    ) -> TokenCostEstimate {
        // Cached input is treated as a subset of input tokens, which matches the
        // common OpenAI usage shape and avoids double-charging cached tokens.
        let uncachedInputTokens = max(0, inputTokens - cachedInputTokens)
        let inputCost = cost(tokens: uncachedInputTokens, perMillion: profile.inputPerMillionUSD)
        let cachedCost = cost(tokens: cachedInputTokens, perMillion: profile.cachedInputPerMillionUSD)
        let outputCost = cost(tokens: outputTokens, perMillion: profile.outputPerMillionUSD)
        let reasoningCost = cost(tokens: reasoningTokens, perMillion: profile.reasoningPerMillionUSD)
        let subtotal = inputCost + cachedCost + outputCost + reasoningCost
        let total = subtotal * max(0, profile.multiplier)

        return TokenCostEstimate(
            inputCostUSD: inputCost,
            cachedInputCostUSD: cachedCost,
            outputCostUSD: outputCost,
            reasoningCostUSD: reasoningCost,
            totalCostUSD: total,
            pricingProfileName: profile.name
        )
    }

    public static func estimate(
        samples: [TokenUsageSample],
        reasoningTokens: Int = 0,
        profile: TokenPricingProfile
    ) -> TokenCostEstimate {
        let input = samples.reduce(0) { $0 + $1.inputTokens }
        let cached = samples.reduce(0) { $0 + $1.cachedInputTokens }
        let output = samples.reduce(0) { $0 + $1.outputTokens }
        let sampleReasoning = samples.reduce(0) { $0 + $1.reasoningTokens }
        return estimate(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: sampleReasoning + reasoningTokens,
            profile: profile
        )
    }

    private static func cost(tokens: Int, perMillion: Double) -> Double {
        Double(max(0, tokens)) / 1_000_000 * perMillion
    }
}
