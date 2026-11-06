// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3

/// Metadata helper that queries Antigravity conversation title and workspace.
enum AntigravityMetadata {
    private static var cache: [String: String] = [:]
    private static var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversation_summaries.db").path
    }

    static func title(for sessionID: String) -> String? {
        if let cached = cache[sessionID] { return cached }
        guard !sessionID.isEmpty else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT title, workspace_uris FROM conversation_summaries WHERE conversation_id = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let uris = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""

            var result = ""
            if let range = uris.range(of: "file://") {
                let sub = uris[range.upperBound...]
                let end = sub.firstIndex(of: "\"") ?? sub.endIndex
                let rawPath = String(sub[..<end]).removingPercentEncoding ?? String(sub[..<end])
                let proj = AgentLogParser.projectName(rawPath)
                if !proj.isEmpty && proj != "antigravity" && proj != "brain" {
                    result = proj
                }
            }
            if result.isEmpty && !title.isEmpty {
                result = String(title.prefix(40))
            }
            if !result.isEmpty {
                cache[sessionID] = result
                return result
            }
        }
        return nil
    }

    static func isRunning(session: String) -> Bool {
        guard !session.isEmpty else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT status, not_fully_idle FROM conversation_summaries WHERE conversation_id = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let status = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let idle = sqlite3_column_int(stmt, 1)
            return status == "CASCADE_RUN_STATUS_RUNNING" || idle == 1
        }
        return false
    }

    static func runningSessionIDs() -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT conversation_id FROM conversation_summaries WHERE status = 'CASCADE_RUN_STATUS_RUNNING' OR not_fully_idle = 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }), !id.isEmpty {
                ids.append(id)
            }
        }
        return ids
    }
}

/// Reads Antigravity transcript session logs.
/// Located in `~/.gemini/antigravity/brain/<session-id>/.system_generated/logs/transcript.jsonl`.
/// USER_INPUT opens a turn, PLANNER_RESPONSE records token usage and completes or continues turns.
struct AntigravityReader: AgentHarnessReader {
    var provider: AgentProvider { .antigravity }

    func parse(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let json = AgentLogParser.object(line) else { return [] }
        let type = json["type"] as? String ?? ""
        let date = AgentLogParser.timestamp(json["created_at"]) ?? now

        switch type {
        case "USER_INPUT":
            if let content = json["content"] as? String {
                extractContext(from: content, state: &state)
            }
            let entry: AgentLogEntry = state.turnOpen ? .turnActive(date) : .turnBegan(date)
            state.turnOpen = true
            return [entry, .turnContext(model: state.model.isEmpty ? "Gemini 3.8 Flash" : state.model,
                                        project: state.project.isEmpty ? "Antigravity" : state.project)]

        case "PLANNER_RESPONSE":
            return parsePlannerResponse(json, date: date, state: &state, now: now)

        case "GENERIC", "SYSTEM_MESSAGE":
            if !state.turnOpen {
                state.turnOpen = true
                return [.turnBegan(date),
                        .turnContext(model: state.model.isEmpty ? "Gemini 3.8 Flash" : state.model,
                                    project: state.project.isEmpty ? "Antigravity" : state.project),
                        .turnActive(date)]
            }
            return [.turnActive(date)]

        default:
            return []
        }
    }

    private func extractContext(from content: String, state: inout AgentLogState) {
        if let range = content.range(of: "Model Selection` from ") {
            let after = content[range.upperBound...]
            if let toRange = after.range(of: " to ") {
                let modelPart = after[toRange.upperBound...]
                let modelName: String
                if let parenIndex = modelPart.firstIndex(of: "(") {
                    modelName = String(modelPart[..<parenIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let endLine = modelPart.firstIndex(of: "\n") {
                    modelName = String(modelPart[..<endLine]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    modelName = String(modelPart.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !modelName.isEmpty {
                    state.model = AgentLogParser.native(modelName)
                }
            }
        }
        if state.session.isEmpty, let sessionRange = content.range(of: "Conversation ID: ") {
            let sessionPart = content[sessionRange.upperBound...]
            let sessionID = sessionPart.prefix(while: { !$0.isWhitespace && $0 != "\n" && $0 != "<" })
            if !sessionID.isEmpty {
                state.session = AgentLogParser.native(String(sessionID))
            }
        }
        if !state.session.isEmpty, let title = AntigravityMetadata.title(for: state.session) {
            state.project = title
        } else if state.project.isEmpty || state.project == "Antigravity" {
            if let reqRange = content.range(of: "<USER_REQUEST>") {
                let after = content[reqRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = after.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !firstLine.isEmpty && !firstLine.hasPrefix("<") {
                    state.project = String(firstLine.prefix(40))
                }
            }
        }
    }

    private func parsePlannerResponse(_ json: [String: Any], date: Date, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        var entries: [AgentLogEntry] = []

        let inputTokens = AgentLogParser.int(json["input_tokens"])
        let outputTokens = AgentLogParser.int(json["output_tokens"])
        let cacheReadTokens = AgentLogParser.int(json["cache_read_tokens"])
        let tokens = AgentTokens(input: inputTokens, cacheWrite: 0, cacheRead: cacheReadTokens, output: outputTokens, reasoning: 0)

        let stepIndex = AgentLogParser.int(json["step_index"])
        let model = state.model.isEmpty ? "Gemini 3.8 Flash" : state.model
        let session = state.session.isEmpty ? "session" : state.session

        if let title = AntigravityMetadata.title(for: session) {
            state.project = title
        }
        let project = state.project.isEmpty ? "Antigravity" : state.project

        // Price calculation: default Gemini pricing rates ($ per 1M tokens)
        let (inputPrice, outputPrice, cachePrice): (Double, Double, Double) = {
            let lower = model.lowercased()
            if lower.contains("pro") {
                return (1.25, 5.0, 0.3125)
            } else if lower.contains("opus") {
                return (5.0, 25.0, 0.5)
            } else if lower.contains("argon") || lower.contains("ultra") {
                return (2.5, 10.0, 0.625)
            } else {
                // Flash / default
                return (0.15, 0.60, 0.0375)
            }
        }()

        let cost = (Double(tokens.input) * inputPrice
                    + Double(tokens.cacheRead) * cachePrice
                    + Double(tokens.output) * outputPrice) / 1_000_000
        let savings = max(0, Double(tokens.cacheRead) * (inputPrice - cachePrice) / 1_000_000)

        if tokens.total > 0 {
            let key = "antigravity:\(session):\(stepIndex)"
            let billable = AgentBillable(tokens: tokens)
            let record = AgentUsageRecord(
                provider: .antigravity,
                date: date,
                model: model,
                project: project,
                session: session,
                requests: 1,
                tokens: tokens,
                cost: cost,
                savings: savings,
                reportedCost: true
            )
            entries.append(.usage(key: key, record: record, billable: billable))
        }

        let toolCalls = json["tool_calls"] as? [[String: Any]] ?? []
        let status = json["status"] as? String ?? ""
        if status == "DONE" && toolCalls.isEmpty {
            if AntigravityMetadata.isRunning(session: session) {
                if !state.turnOpen {
                    state.turnOpen = true
                    entries.append(.turnBegan(date))
                    entries.append(.turnContext(model: model, project: project))
                }
                entries.append(.turnActive(date))
            } else if state.turnOpen {
                state.turnOpen = false
                entries.append(.turnEnded(date, completed: true, duration: nil))
            }
        } else {
            if !state.turnOpen {
                state.turnOpen = true
                entries.append(.turnBegan(date))
                entries.append(.turnContext(model: model, project: project))
            }
            entries.append(.turnActive(date))
        }

        return entries
    }
}

/// Reads quota summary from local Antigravity Language Server (running ConnectRPC on HTTPS).
enum AntigravityQuotaReader {
    struct QuotaBucket {
        let id: String
        let displayName: String
        let remainingFraction: Double
        let resetTime: Date?
        let window: String
    }

    struct QuotaResult {
        let plan: String
        let sessionLimit: QuotaBucket?
        let weeklyLimit: QuotaBucket?
    }

    static func query() -> QuotaResult? {
        // 1. Find language_server PID and CSRF token from ps
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ww", "-eo", "pid,command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        var targetPID = ""
        var csrfToken = ""
        for line in output.components(separatedBy: "\n") {
            if line.contains("language_server") && line.contains("--csrf_token") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if let first = parts.first { targetPID = String(first) }
                if let r = line.range(of: "--csrf_token") {
                    let sub = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    csrfToken = String(sub.prefix(while: { !$0.isWhitespace }))
                }
                break
            }
        }
        guard !targetPID.isEmpty, !csrfToken.isEmpty else { return nil }

        // 2. Find listening port for targetPID using lsof
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-Pan", "-p", targetPID, "-iTCP", "-sTCP:LISTEN"]
        let lpipe = Pipe()
        lsof.standardOutput = lpipe
        guard (try? lsof.run()) != nil else { return nil }
        let ldata = lpipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()

        let lout = String(decoding: ldata, as: UTF8.self)
        var ports: [Int] = []
        for line in lout.components(separatedBy: "\n") {
            if let colon = line.range(of: ":") {
                let sub = line[colon.upperBound...]
                let pStr = sub.prefix(while: { $0.isNumber })
                if let p = Int(pStr), p > 1024, !ports.contains(p) { ports.append(p) }
            }
        }

        // 3. Query RetrieveUserQuotaSummary via curl to bypass self-signed local TLS effortlessly
        for port in ports {
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = [
                "-k", "-s", "--max-time", "2",
                "-X", "POST", "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
                "-H", "Content-Type: application/json",
                "-H", "x-codeium-csrf-token: \(csrfToken)",
                "-d", "{}"
            ]
            let cpipe = Pipe()
            curl.standardOutput = cpipe
            guard (try? curl.run()) != nil else { continue }
            let cdata = cpipe.fileHandleForReading.readDataToEndOfFile()
            curl.waitUntilExit()

            guard !cdata.isEmpty,
                  let json = (try? JSONSerialization.jsonObject(with: cdata)) as? [String: Any],
                  let resp = json["response"] as? [String: Any],
                  let groups = resp["groups"] as? [[String: Any]] else {
                continue
            }

            var sessionBucket: QuotaBucket?
            var weeklyBucket: QuotaBucket?

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoWhole = ISO8601DateFormatter()

            for group in groups {
                let groupName = group["displayName"] as? String ?? ""
                guard groupName == "Gemini Models" else { continue }
                let buckets = group["buckets"] as? [[String: Any]] ?? []
                for b in buckets {
                    let id = b["bucketId"] as? String ?? ""
                    let name = b["displayName"] as? String ?? ""
                    let frac = b["remainingFraction"] as? Double ?? 0
                    let win = b["window"] as? String ?? ""
                    let resetStr = b["resetTime"] as? String ?? ""
                    let resetDate = iso.date(from: resetStr) ?? isoWhole.date(from: resetStr)
                    let bucket = QuotaBucket(id: id, displayName: name, remainingFraction: frac, resetTime: resetDate, window: win)
                    if win == "5h" { sessionBucket = bucket }
                    if win == "weekly" { weeklyBucket = bucket }
                }
            }
            return QuotaResult(plan: "Google AI Pro", sessionLimit: sessionBucket, weeklyLimit: weeklyBucket)
        }
        return nil
    }
}
