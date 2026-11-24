import Foundation
import Darwin

struct QuotaDebugReport {
    var lines: [String] = []
    mutating func log(_ msg: String) {
        lines.append(msg)
    }
    var text: String { lines.joined(separator: "\n") }
}

final class QuotaService: @unchecked Sendable {
    private(set) var lastDebugReport = QuotaDebugReport()

    func fetchQuota() async throws -> QuotaSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let snapshot = try self.fetchViaAgyCLI()
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchViaAgyCLI() throws -> QuotaSnapshot {
        var report = QuotaDebugReport()
        report.log("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")

        guard let agyPath = findAgyBinary() else {
            report.log("agy binary not found")
            lastDebugReport = report
            throw QuotaFetchError.rpcFailed("ไม่พบคำสั่ง agy CLI บนเครื่อง")
        }
        report.log("Using agy binary: \(agyPath)")

        let rawOutput = try runAgyUsageInPTY(agyPath: agyPath, report: &report)
        let cleaned = Self.stripANSI(rawOutput)

        let previewLines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        report.log("Captured \(cleaned.count) clean chars (\(previewLines.count) non-empty lines)")

        if let snapshot = Self.parseAgyUsageText(cleaned) {
            report.log("Parsed from agy /usage: 5h=\(String(describing: snapshot.fiveHourPercent))%, weekly=\(String(describing: snapshot.weeklyPercent))%, plan=\(snapshot.accountPlan ?? "-")")
            lastDebugReport = report
            return snapshot
        }

        let sample = previewLines.suffix(35).joined(separator: "\n")
        report.log("Could not parse 5h/weekly percentages. Captured text tail:\n\(sample)")
        lastDebugReport = report
        throw QuotaFetchError.noQuotaData
    }

    private func findAgyBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/.gemini/bin/agy"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func runAgyUsageInPTY(agyPath: String, report: inout QuotaDebugReport) throws -> String {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var winSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&masterFD, &slaveFD, nil, nil, &winSize) == 0 else {
            throw QuotaFetchError.rpcFailed("ไม่สามารถสร้าง PTY ได้ (errno=\(errno))")
        }

        defer {
            if masterFD >= 0 { close(masterFD) }
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agyPath)
        process.arguments = []
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["COLUMNS"] = "120"
        env["LINES"] = "40"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        process.environment = env

        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
        } catch {
            close(slaveFD)
            throw QuotaFetchError.rpcFailed("เปิด agy ไม่สำเร็จ: \(error.localizedDescription)")
        }

        close(slaveFD)

        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        var buffer = Data()
        let startTime = Date()
        let maxTimeout: TimeInterval = 18.0

        var confirmedTrust = false
        var dismissedBanner = false
        var sentUsageText = false
        var sentUsageEnter = false
        var sentSecondEnter = false
        var sentUsageTextTime: Date?
        var sentUsageEnterTime: Date?
        var firstParsedTime: Date?

        var readBuf = [UInt8](repeating: 0, count: 8192)

        func sendPTY(_ str: String) {
            _ = str.withCString { ptr in
                write(masterFD, ptr, strlen(ptr))
            }
        }

        while Date().timeIntervalSince(startTime) < maxTimeout {
            var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            let ret = poll(&pfd, 1, 100)

            if ret > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                while true {
                    let n = read(masterFD, &readBuf, readBuf.count)
                    if n > 0 {
                        let chunk = Data(readBuf[0..<n])
                        buffer.append(chunk)

                        if let chunkStr = String(data: chunk, encoding: .utf8),
                           chunkStr.contains("\u{1B}[6n") {
                            sendPTY("\u{1B}[1;1R")
                        }
                    } else {
                        break
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let currentText = String(data: buffer, encoding: .utf8) ?? ""
            let cleaned = Self.stripANSI(currentText)
            let lowerCleaned = cleaned.lowercased()

            // Step 1: If folder trust prompt appears, accept it
            if !confirmedTrust && lowerCleaned.contains("do you trust") {
                sendPTY("\r")
                confirmedTrust = true
                report.log("Confirmed trust prompt at \(String(format: "%.2fs", elapsed))")
                continue
            }

            // Step 2: Wait until main TUI prompt is ready ("? for shortcuts")
            let promptReady = lowerCleaned.contains("? for shortcuts")

            // Optional: dismiss announcement banner if present
            if promptReady && !dismissedBanner && lowerCleaned.contains("esc to dismiss") {
                sendPTY("\u{1B}")
                dismissedBanner = true
                report.log("Dismissed banner at \(String(format: "%.2fs", elapsed))")
                usleep(200_000)
                continue
            }

            // Step 3: Type `/usage` once prompt is ready
            if promptReady && !sentUsageText {
                // Give TUI 0.3s to settle before typing
                usleep(300_000)
                sendPTY("/usage")
                sentUsageText = true
                sentUsageTextTime = Date()
                report.log("Typed /usage at \(String(format: "%.2fs", elapsed))")
                continue
            }

            // Step 4: Press Enter 0.25s after typing `/usage`
            if sentUsageText && !sentUsageEnter,
               let t = sentUsageTextTime,
               Date().timeIntervalSince(t) >= 0.25 {
                sendPTY("\r")
                sentUsageEnter = true
                sentUsageEnterTime = Date()
                report.log("Sent Enter for /usage at \(String(format: "%.2fs", elapsed))")
                continue
            }

            // Step 5: Check if quota numbers appeared; if not after 1.5s, press Enter once more (in case autocomplete needed confirm)
            if sentUsageEnter {
                if let snap = Self.parseAgyUsageText(cleaned) {
                    if snap.fiveHourRemaining != nil && snap.weeklyRemaining != nil {
                        if firstParsedTime == nil {
                            firstParsedTime = Date()
                        } else if Date().timeIntervalSince(firstParsedTime!) >= 0.4 {
                            break
                        }
                    } else if let enterAt = sentUsageEnterTime, Date().timeIntervalSince(enterAt) >= 4.5 {
                        break
                    }
                } else if !sentSecondEnter,
                          let enterAt = sentUsageEnterTime,
                          Date().timeIntervalSince(enterAt) >= 1.5 {
                    sendPTY("\r")
                    sentSecondEnter = true
                    report.log("Sent second Enter at \(String(format: "%.2fs", elapsed))")
                }
            }

            if !process.isRunning {
                break
            }
        }

        // Cleanly exit agy
        sendPTY("\u{1B}\u{04}\u{04}")
        usleep(100_000)
        if process.isRunning {
            process.terminate()
            usleep(150_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        return String(data: buffer, encoding: .utf8) ?? ""
    }

    // MARK: - ANSI Stripping & Text Parsing

    static func stripANSI(_ input: String) -> String {
        var text = input

        // NOTE: Do NOT use raw strings (#"..."#) with \u{1B} — use \\x1B for real ESC byte (0x1B) in ICU regex!
        let patterns: [(String, String)] = [
            // OSC sequences: ESC ] ... (BEL or ESC \)
            ("\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)", ""),
            // CSI cursor positioning -> newline
            ("\\x1B\\[\\d*;\\d*[Hf]", "\n"),
            // CSI cursor forward -> space
            ("\\x1B\\[\\d*C", " "),
            // Remaining CSI sequences (including private modes like [?25h, [>4;2m, [<1u, [K, [m)
            ("\\x1B\\[[0-9;?<>]*[ -/]*[@-~]", ""),
            // Other 2-byte ESC sequences
            ("\\x1B[@-Z\\\\-_]", ""),
            // Carriage return
            ("\\r", "\n")
        ]

        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
            }
        }

        return text
    }

    static func parseAgyUsageText(_ text: String) -> QuotaSnapshot? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }

        let email = extractEmail(from: lines)
        let plan = extractPlan(from: lines)

        // Scope to the Gemini section if a Gemini heading exists inside the usage panel
        let scopedLines: [String]
        if let geminiStart = lines.lastIndex(where: { line in
            let l = line.lowercased()
            return (l.contains("gemini models") || l == "gemini") && !l.contains("claude")
        }) {
            var slice: [String] = []
            for idx in geminiStart..<lines.count {
                let l = lines[idx].lowercased()
                if idx > geminiStart && (l.contains("claude") || l.contains("third-party") || l.contains("partner")) {
                    break
                }
                slice.append(lines[idx])
            }
            scopedLines = slice
        } else {
            scopedLines = lines
        }

        let (fiveHour, weekly) = extractPercentages(from: scopedLines)
        if fiveHour != nil || weekly != nil {
            return QuotaSnapshot(
                provider: .gemini,
                fiveHourRemaining: fiveHour,
                weeklyRemaining: weekly,
                fiveHourResetTime: nil,
                weeklyResetTime: nil,
                groupName: "Gemini (agy /usage)",
                accountEmail: email,
                accountPlan: plan,
                fetchedAt: Date()
            )
        }

        let (fallbackFive, fallbackWeekly) = extractPercentages(from: lines)
        if fallbackFive != nil || fallbackWeekly != nil {
            return QuotaSnapshot(
                provider: .gemini,
                fiveHourRemaining: fallbackFive,
                weeklyRemaining: fallbackWeekly,
                fiveHourResetTime: nil,
                weeklyResetTime: nil,
                groupName: "Gemini (agy /usage)",
                accountEmail: email,
                accountPlan: plan,
                fetchedAt: Date()
            )
        }

        return nil
    }

    private static func extractEmail(from lines: [String]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) else {
            return nil
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let r = Range(match.range, in: line) {
                return String(line[r])
            }
        }
        return nil
    }

    private static func extractPlan(from lines: [String]) -> String? {
        for line in lines {
            if line.contains("Google AI Ultra") { return "Google AI Ultra" }
            if line.contains("Google AI Pro") { return "Google AI Pro" }
        }
        return nil
    }

    private static func extractPercentages(from lines: [String]) -> (fiveHour: Double?, weekly: Double?) {
        var fiveHour: Double?
        var weekly: Double?

        for i in 0..<lines.count {
            let lower = lines[i].lowercased()

            let isFiveHour = lower.contains("five hour")
                || lower.contains("5-hour")
                || lower.contains("5 hour")
                || lower.contains("5h")
            let isWeekly = lower.contains("weekly")
                || lower.contains("7-day")
                || lower.contains("7 day")

            if isFiveHour && fiveHour == nil {
                if let pct = findNearestPercent(in: lines, around: i) {
                    fiveHour = convertToRemainingFraction(pct, lineContext: lower)
                }
            }
            if isWeekly && weekly == nil {
                if let pct = findNearestPercent(in: lines, around: i) {
                    weekly = convertToRemainingFraction(pct, lineContext: lower)
                }
            }
        }

        return (fiveHour, weekly)
    }

    private static func findNearestPercent(in lines: [String], around index: Int) -> Double? {
        let offsets = [0, 1, 2, -1]
        for offset in offsets {
            let idx = index + offset
            guard idx >= 0 && idx < lines.count else { continue }
            if let pct = firstPercent(in: lines[idx]) {
                return pct
            }
        }
        return nil
    }

    private static func firstPercent(in line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let numRange = Range(match.range(at: 1), in: line),
              let value = Double(line[numRange]),
              value >= 0.0 && value <= 100.0 else {
            return nil
        }
        return value
    }

    private static func convertToRemainingFraction(_ percent: Double, lineContext: String) -> Double {
        if lineContext.contains("used") && !lineContext.contains("remaining") && !lineContext.contains("left") {
            return min(max(1.0 - (percent / 100.0), 0.0), 1.0)
        }
        return min(max(percent / 100.0, 0.0), 1.0)
    }
}
