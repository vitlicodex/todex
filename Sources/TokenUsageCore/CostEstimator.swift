import Foundation

public struct TokenPricingProfile: Codable, Equatable, Sendable {
    public var name: String
    public var inputPerMillionUSD: Double
    public var cachedInputPerMillionUSD: Double
    public var outputPerMillionUSD: Double
    public var reasoningPerMillionUSD: Double
    public var multiplier: Double

    public init(
        name: String,
        inputPerMillionUSD: Double,
        cachedInputPerMillionUSD: Double,
        outputPerMillionUSD: Double,
        reasoningPerMillionUSD: Double = 0,
        multiplier: Double = 1
    ) {
        self.name = name
        self.inputPerMillionUSD = inputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.reasoningPerMillionUSD = reasoningPerMillionUSD
        self.multiplier = multiplier
    }
}

public struct EstimatedTokenCost: Codable, Equatable, Sendable {
    public var inputCostUSD: Double
    public var cachedInputCostUSD: Double
    public var outputCostUSD: Double
    public var reasoningCostUSD: Double
    public var totalCostUSD: Double
    public var pricingProfileName: String

    public init(
        inputCostUSD: Double,
        cachedInputCostUSD: Double,
        outputCostUSD: Double,
        reasoningCostUSD: Double,
        totalCostUSD: Double,
        pricingProfileName: String
    ) {
        self.inputCostUSD = inputCostUSD
        self.cachedInputCostUSD = cachedInputCostUSD
        self.outputCostUSD = outputCostUSD
        self.reasoningCostUSD = reasoningCostUSD
        self.totalCostUSD = totalCostUSD
        self.pricingProfileName = pricingProfileName
    }
}

public enum CostEstimator {
    public static func estimate(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        profile: TokenPricingProfile
    ) -> EstimatedTokenCost {
        // Cached input is treated as a subset of input tokens, which matches the
        // common OpenAI usage shape and avoids double-charging cached tokens.
        let uncachedInputTokens = max(0, inputTokens - cachedInputTokens)
        let inputCost = cost(tokens: uncachedInputTokens, perMillion: profile.inputPerMillionUSD)
        let cachedCost = cost(tokens: cachedInputTokens, perMillion: profile.cachedInputPerMillionUSD)
        let outputCost = cost(tokens: outputTokens, perMillion: profile.outputPerMillionUSD)
        let reasoningCost = cost(tokens: reasoningTokens, perMillion: profile.reasoningPerMillionUSD)
        let subtotal = inputCost + cachedCost + outputCost + reasoningCost
        let total = subtotal * max(0, profile.multiplier)

        return EstimatedTokenCost(
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
    ) -> EstimatedTokenCost {
        let input = samples.reduce(0) { $0 + $1.inputTokens }
        let cached = samples.reduce(0) { $0 + $1.cachedInputTokens }
        let output = samples.reduce(0) { $0 + $1.outputTokens }
        return estimate(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoningTokens,
            profile: profile
        )
    }

    private static func cost(tokens: Int, perMillion: Double) -> Double {
        Double(max(0, tokens)) / 1_000_000 * perMillion
    }
}
