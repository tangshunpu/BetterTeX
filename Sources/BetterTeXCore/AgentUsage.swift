import Foundation
import CoreFoundation

/// The latest request's context, never the sum of tokens billed over a conversation.
public struct AgentContextUsage: Equatable {
    public let usedTokens: Int?
    public let limitTokens: Int?
    public let model: String?
    public init(usedTokens: Int?, limitTokens: Int?, model: String? = nil) {
        self.usedTokens = usedTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.limitTokens = limitTokens.flatMap { $0 > 0 ? $0 : nil }
        self.model = model
    }
    public var fraction: Double? {
        guard let usedTokens, let limitTokens else { return nil }
        return min(1, Double(usedTokens) / Double(limitTokens))
    }
    public func merging(_ previous: AgentContextUsage?) -> AgentContextUsage {
        guard let previous, model == previous.model else { return self }
        return .init(usedTokens: usedTokens ?? previous.usedTokens, limitTokens: limitTokens ?? previous.limitTokens, model: model)
    }
}

public struct AgentQuotaWindow: Equatable {
    public let id: String
    public let usedPercent: Double?
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public init(id: String, usedPercent: Double?, durationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.usedPercent = usedPercent.flatMap { $0.isFinite && $0 >= 0 ? min(100, $0) : nil }
        self.durationMinutes = durationMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.resetsAt = resetsAt
    }
    public func remainingPercent(at now: Date = Date()) -> Double? {
        guard resetsAt == nil || resetsAt! > now else { return nil }
        return usedPercent.map { 100 - $0 }
    }
    public var title: String {
        if let minutes = durationMinutes {
            if minutes % 1440 == 0 { return L10n.tr("\(minutes / 1440) 天") }
            if minutes % 60 == 0 { return L10n.tr("\(minutes / 60) 小时") }
            return L10n.tr("\(minutes) 分钟")
        }
        switch id {
        case "five_hour": return L10n.tr("5 小时")
        case "seven_day": return L10n.tr("7 天")
        case "primary": return L10n.tr("主要额度")
        case "secondary": return L10n.tr("次要额度")
        default: return L10n.tr("使用额度")
        }
    }
}

public struct AgentQuotaSnapshot: Equatable {
    public let windows: [AgentQuotaWindow]
    public let observedAt: Date
    public let status: String?
    public let plan: String?
    public init(windows: [AgentQuotaWindow], observedAt: Date = Date(), status: String? = nil, plan: String? = nil) {
        self.windows = windows; self.observedAt = observedAt; self.status = status; self.plan = plan
    }
    public func remainingPercent(at now: Date = Date()) -> Double? {
        // Old snapshots are not a promise that the account still has that much quota.
        guard isCurrent(at: now), status != "rejected", status != "credits_required" else { return nil }
        let values = windows.compactMap { $0.remainingPercent(at: now) }
        guard values.count == windows.count else { return nil }
        return values.min()
    }
    public func isCurrent(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(observedAt) < 300 && windows.allSatisfy { $0.resetsAt == nil || $0.resetsAt! > now }
    }
    public static func codex(_ object: [String: Any], observedAt: Date = Date()) -> AgentQuotaSnapshot? {
        let root = object["result"] as? [String: Any] ?? object
        let buckets = root["rateLimitsByLimitId"] as? [String: [String: Any]]
        let limits = buckets?["codex"] ?? root["rateLimits"] as? [String: Any] ?? root
        let windows = ["primary", "secondary"].compactMap { name -> AgentQuotaWindow? in
            guard let value = limits[name] as? [String: Any], let percent = number(value["usedPercent"] ?? value["used_percent"]) else { return nil }
            return .init(id: name, usedPercent: percent, durationMinutes: integer(value["windowDurationMins"] ?? value["window_minutes"]),
                         resetsAt: number(value["resetsAt"] ?? value["resets_at"]).map(Date.init(timeIntervalSince1970:)))
        }
        let reached = limits["rateLimitReachedType"] as? String ?? limits["rate_limit_reached_type"] as? String
        guard !windows.isEmpty || reached != nil else { return nil }
        return .init(windows: windows, observedAt: observedAt, status: reached == nil ? nil : "rejected", plan: limits["planType"] as? String ?? limits["plan_type"] as? String)
    }
    public static func claude(_ info: [String: Any], observedAt: Date = Date()) -> AgentQuotaSnapshot? {
        guard let status = info["status"] as? String else { return nil }
        let type = info["rateLimitType"] as? String ?? "current"
        let window = AgentQuotaWindow(id: type, usedPercent: number(info["utilization"]).map { $0 * 100 },
                                      resetsAt: number(info["resetsAt"]).map(Date.init(timeIntervalSince1970:)))
        return .init(windows: [window], observedAt: observedAt, status: info["errorCode"] as? String ?? status)
    }
}

// JSON booleans and negative/overflowing values must not turn into token counts.
func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
    return value.doubleValue
}
func integer(_ value: Any?) -> Int? {
    guard let value = number(value), value >= 0, value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
    return Int(value)
}
