import Foundation

enum AIProvider: String, CaseIterable {
    case gemini
    case chatgpt

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .chatgpt: return "ChatGPT"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .gemini: return "1"
        case .chatgpt: return "2"
        }
    }
}

struct QuotaSnapshot: Equatable {
    let provider: AIProvider
    let fiveHourRemaining: Double?   // 0.0 ... 1.0
    let weeklyRemaining: Double?     // 0.0 ... 1.0
    let fiveHourResetTime: Date?
    let weeklyResetTime: Date?
    let groupName: String?
    let accountEmail: String?
    let accountPlan: String?
    let fetchedAt: Date

    var fiveHourPercent: Int? {
        guard let value = fiveHourRemaining else { return nil }
        return Int((clamp(value) * 100.0).rounded())
    }

    var weeklyPercent: Int? {
        guard let value = weeklyRemaining else { return nil }
        return Int((clamp(value) * 100.0).rounded())
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}

enum QuotaFetchError: LocalizedError {
    case languageServerNotFound
    case noListeningPorts
    case rpcFailed(String)
    case noQuotaData
    case chatGPTAuthNotFound
    case chatGPTAuthInvalid
    case chatGPTRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .languageServerNotFound:
            return "ไม่พบ Antigravity Language Server ที่กำลังทำงานอยู่"
        case .noListeningPorts:
            return "ไม่พบพอร์ตของ Antigravity Language Server"
        case .rpcFailed(let detail):
            return "เชื่อมต่อ Gemini Quota API ไม่สำเร็จ: \(detail)"
        case .noQuotaData:
            return "ไม่พบข้อมูล Quota ในคำตอบจากเซิร์ฟเวอร์"
        case .chatGPTAuthNotFound:
            return "ไม่พบไฟล์ ~/.codex/auth.json (กรุณารัน codex login ก่อน)"
        case .chatGPTAuthInvalid:
            return "ไม่พบ access_token ใน ~/.codex/auth.json"
        case .chatGPTRequestFailed(let detail):
            return "เชื่อมต่อ ChatGPT Usage API ไม่สำเร็จ: \(detail)"
        }
    }
}

enum QuotaJSONParser {
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Gemini (Antigravity) Parser

    static func parse(data: Data) -> QuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let userStatus = root["userStatus"] as? [String: Any]
        let email = userStatus?["email"] as? String
        let plan = (userStatus?["accountPlan"] as? String)
            ?? ((userStatus?["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String

        // Path 1: RetrieveUserQuotaSummary or GetUserStatus -> groups[]
        let groups: [[String: Any]]? =
            (root["response"] as? [String: Any])?["groups"] as? [[String: Any]]
            ?? root["groups"] as? [[String: Any]]
            ?? (userStatus?["quotaSummary"] as? [String: Any])?["groups"] as? [[String: Any]]
            ?? (root["quotaSummary"] as? [String: Any])?["groups"] as? [[String: Any]]

        if let groups, !groups.isEmpty {
            let targetGroup = groups.first(where: { isGeminiGroup($0) }) ?? groups[0]
            let groupName = (targetGroup["displayName"] as? String) ?? (targetGroup["id"] as? String)
            let buckets = (targetGroup["buckets"] as? [[String: Any]]) ?? []

            var fiveHourFrac: Double?
            var weeklyFrac: Double?
            var fiveHourReset: Date?
            var weeklyReset: Date?

            for bucket in buckets {
                let kind = classifyBucket(bucket)
                let frac = extractFraction(bucket)
                let reset = parseDate(bucket["resetTime"] as? String)

                switch kind {
                case .fiveHour:
                    if fiveHourFrac == nil {
                        fiveHourFrac = frac
                        fiveHourReset = reset
                    }
                case .weekly:
                    if weeklyFrac == nil {
                        weeklyFrac = frac
                        weeklyReset = reset
                    }
                case .unknown:
                    break
                }
            }

            if fiveHourFrac != nil || weeklyFrac != nil {
                return QuotaSnapshot(
                    provider: .gemini,
                    fiveHourRemaining: fiveHourFrac,
                    weeklyRemaining: weeklyFrac,
                    fiveHourResetTime: fiveHourReset,
                    weeklyResetTime: weeklyReset,
                    groupName: groupName,
                    accountEmail: email,
                    accountPlan: plan,
                    fetchedAt: Date()
                )
            }
        }

        // Path 2: Fallback for GetUserStatus or GetCommandModelConfigs -> clientModelConfigs[]
        let configs: [[String: Any]]? =
            (userStatus?["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]
            ?? root["clientModelConfigs"] as? [[String: Any]]

        if let configs {
            let geminiConfigs = configs.filter { cfg in
                let label = (cfg["label"] as? String ?? "").lowercased()
                let alias = ((cfg["modelOrAlias"] as? [String: Any])?["model"] as? String ?? "").lowercased()
                return label.contains("gemini") || alias.contains("gemini")
            }

            let candidates = geminiConfigs.isEmpty ? configs : geminiConfigs
            let fractions = candidates.compactMap { cfg -> (Double, Date?)? in
                guard let quotaInfo = cfg["quotaInfo"] as? [String: Any],
                      let frac = extractFraction(quotaInfo) else {
                    return nil
                }
                return (frac, parseDate(quotaInfo["resetTime"] as? String))
            }

            if let minEntry = fractions.min(by: { $0.0 < $1.0 }) {
                return QuotaSnapshot(
                    provider: .gemini,
                    fiveHourRemaining: minEntry.0,
                    weeklyRemaining: nil,
                    fiveHourResetTime: minEntry.1,
                    weeklyResetTime: nil,
                    groupName: "Gemini",
                    accountEmail: email,
                    accountPlan: plan,
                    fetchedAt: Date()
                )
            }
        }

        return nil
    }

    // MARK: - ChatGPT (OpenAI / Codex wham/usage) Parser

    static func parseChatGPTUsage(data: Data, email: String? = nil) -> QuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let planRaw = root["plan_type"] as? String
        let plan = planRaw.map { formatPlanName($0) }

        let rateLimit = root["rate_limit"] as? [String: Any]
        let primary = rateLimit?["primary_window"] as? [String: Any]
        let secondary = rateLimit?["secondary_window"] as? [String: Any]

        let fiveHour = parseChatGPTWindow(primary)
        let weekly = parseChatGPTWindow(secondary)

        guard fiveHour.remaining != nil || weekly.remaining != nil else {
            return nil
        }

        return QuotaSnapshot(
            provider: .chatgpt,
            fiveHourRemaining: fiveHour.remaining,
            weeklyRemaining: weekly.remaining,
            fiveHourResetTime: fiveHour.resetTime,
            weeklyResetTime: weekly.resetTime,
            groupName: "ChatGPT",
            accountEmail: email ?? (root["email"] as? String),
            accountPlan: plan,
            fetchedAt: Date()
        )
    }

    private static func parseChatGPTWindow(_ window: [String: Any]?) -> (remaining: Double?, resetTime: Date?) {
        guard let window else { return (nil, nil) }

        var remaining: Double?
        if let usedPct = (window["used_percent"] as? NSNumber)?.doubleValue {
            remaining = min(max(1.0 - (usedPct / 100.0), 0.0), 1.0)
        } else if let remPct = (window["remaining_percent"] as? NSNumber)?.doubleValue {
            remaining = min(max(remPct / 100.0, 0.0), 1.0)
        }

        var resetDate: Date?
        if let resetAt = (window["reset_at"] as? NSNumber)?.doubleValue, resetAt > 0 {
            resetDate = Date(timeIntervalSince1970: resetAt)
        } else if let resetAfter = (window["reset_after_seconds"] as? NSNumber)?.doubleValue, resetAfter > 0 {
            resetDate = Date().addingTimeInterval(resetAfter)
        }

        return (remaining, resetDate)
    }

    private static func formatPlanName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    private enum BucketKind {
        case fiveHour
        case weekly
        case unknown
    }

    private static func isGeminiGroup(_ group: [String: Any]) -> Bool {
        let id = (group["id"] as? String ?? "").lowercased()
        let name = (group["displayName"] as? String ?? "").lowercased()
        return id.contains("gemini") || name.contains("gemini")
    }

    private static func classifyBucket(_ bucket: [String: Any]) -> BucketKind {
        let combined = [
            bucket["window"] as? String ?? "",
            bucket["id"] as? String ?? "",
            bucket["displayName"] as? String ?? "",
            bucket["label"] as? String ?? ""
        ].joined(separator: " ").lowercased()

        if combined.contains("5h") || combined.contains("5-hour") || combined.contains("five") || combined.contains("hour") {
            return .fiveHour
        }
        if combined.contains("week") || combined.contains("7d") || combined.contains("7-day") {
            return .weekly
        }
        return .unknown
    }

    private static func extractFraction(_ dict: [String: Any]) -> Double? {
        if let val = dict["remainingFraction"] as? Double {
            return min(max(val, 0.0), 1.0)
        }
        if let val = dict["remainingFraction"] as? NSNumber {
            return min(max(val.doubleValue, 0.0), 1.0)
        }
        if let pct = dict["remainingPercentage"] as? Double {
            return min(max(pct / 100.0, 0.0), 1.0)
        }
        return nil
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFormatterWithFractional.date(from: string)
            ?? isoFormatterStandard.date(from: string)
    }
}
