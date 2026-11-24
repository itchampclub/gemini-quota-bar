import Foundation

final class ChatGPTQuotaService {
    private let session: URLSession
    private(set) var lastDebugReport = QuotaDebugReport()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 12.0
        self.session = URLSession(configuration: config)
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        var report = QuotaDebugReport()
        report.log("[ChatGPT] Timestamp: \(ISO8601DateFormatter().string(from: Date()))")

        guard let authFile = findAuthFile() else {
            report.log("[ChatGPT] auth.json not found in ~/.codex/auth.json or $CODEX_HOME/auth.json")
            lastDebugReport = report
            throw QuotaFetchError.chatGPTAuthNotFound
        }
        report.log("[ChatGPT] Found auth file: \(authFile.path)")

        let auth = try parseAuthFile(at: authFile)
        report.log("[ChatGPT] Loaded access_token (present), account_id=\(auth.accountId != nil ? "present" : "nil")")

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw QuotaFetchError.chatGPTRequestFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId = auth.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            lastDebugReport = report
            throw QuotaFetchError.chatGPTRequestFailed("Invalid HTTP response")
        }

        report.log("[ChatGPT] GET wham/usage -> HTTP \(http.statusCode) (\(data.count) bytes)")
        guard (200..<300).contains(http.statusCode) else {
            lastDebugReport = report
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaFetchError.chatGPTRequestFailed("Token หมดอายุ (HTTP \(http.statusCode)) กรุณารัน codex login ใหม่")
            }
            throw QuotaFetchError.chatGPTRequestFailed("HTTP \(http.statusCode)")
        }

        guard let snapshot = QuotaJSONParser.parseChatGPTUsage(data: data, email: auth.email) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                report.log("[ChatGPT] Unparsed JSON top keys: \(Array(obj.keys).sorted())")
            }
            lastDebugReport = report
            throw QuotaFetchError.noQuotaData
        }

        report.log("[ChatGPT] Parsed: 5h=\(String(describing: snapshot.fiveHourPercent))%, weekly=\(String(describing: snapshot.weeklyPercent))%, plan=\(snapshot.accountPlan ?? "-")")
        lastDebugReport = report
        return snapshot
    }

    private struct CodexAuth {
        let accessToken: String
        let accountId: String?
        let email: String?
    }

    private func findAuthFile() -> URL? {
        var candidates: [URL] = []

        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            candidates.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".codex/auth.json"))
        candidates.append(home.appendingPathComponent(".config/codex/auth.json"))

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func parseAuthFile(at url: URL) throws -> CodexAuth {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaFetchError.chatGPTAuthInvalid
        }

        let tokens = root["tokens"] as? [String: Any]
        let accessToken = (tokens?["access_token"] as? String)
            ?? (root["access_token"] as? String)
            ?? (root["accessToken"] as? String)

        guard let accessToken, !accessToken.isEmpty else {
            throw QuotaFetchError.chatGPTAuthInvalid
        }

        let accountId = (tokens?["account_id"] as? String)
            ?? (root["account_id"] as? String)
            ?? (root["accountId"] as? String)

        let idToken = (tokens?["id_token"] as? String) ?? (root["id_token"] as? String)
        let email = extractEmailFromJWT(idToken) ?? extractEmailFromJWT(accessToken)

        return CodexAuth(accessToken: accessToken, accountId: accountId, email: email)
    }

    private func extractEmailFromJWT(_ jwt: String?) -> String? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let email = json["email"] as? String { return email }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String {
            return email
        }
        return nil
    }
}
