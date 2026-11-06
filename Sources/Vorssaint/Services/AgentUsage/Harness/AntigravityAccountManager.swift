// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Combine
import AppKit

/// Manages multiple Antigravity account profiles and switching between them.
final class AntigravityAccountManager: ObservableObject {
    static let shared = AntigravityAccountManager()

    @Published private(set) var activeProfileIndex: Int = 1
    @Published private(set) var profile1Email: String = ""
    @Published private(set) var profile2Email: String = ""
    @Published private(set) var isSwitching: Bool = false

    var currentEmail: String {
        activeProfileIndex == 1 ? profile1Email : profile2Email
    }

    private static var baseFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity_profiles", isDirectory: true)
    }

    private static var activeFile: URL {
        baseFolder.appendingPathComponent("active.txt")
    }

    private static var appSupportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity", isDirectory: true)
    }

    private static let authFiles = [
        "Cookies",
        "Cookies-journal",
        "Local Storage",
        "Session Storage",
        "credential-user-scope",
        "app_storage.json",
        "Local State",
        "Preferences",
        "Network Persistent State",
        "Partitions"
    ]

    static let defaultProxyCommands = """
    export https_proxy=http://127.0.0.1:7890
    export http_proxy=http://127.0.0.1:7890
    export all_proxy=socks5://127.0.0.1:7890
    export HTTP_PROXY=http://127.0.0.1:7890
    export HTTPS_PROXY=http://127.0.0.1:7890
    export ALL_PROXY=socks5://127.0.0.1:7890
    open /Applications/Antigravity.app
    """

    init() {
        loadState()
    }

    func loadState() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.baseFolder, withIntermediateDirectories: true)
        if let str = try? String(contentsOf: Self.activeFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let idx = Int(str), idx == 1 || idx == 2 {
            activeProfileIndex = idx
        } else {
            activeProfileIndex = 1
            try? "1".write(to: Self.activeFile, atomically: true, encoding: .utf8)
        }

        let currEmail = readCurrentEmail() ?? ""
        profile1Email = readProfileEmail(index: 1) ?? (activeProfileIndex == 1 ? currEmail : "")
        profile2Email = readProfileEmail(index: 2) ?? (activeProfileIndex == 2 ? currEmail : "")
    }

    func profileFolder(for index: Int) -> URL {
        Self.baseFolder.appendingPathComponent("profile_\(index)", isDirectory: true)
    }

    private func readProfileEmail(index: Int) -> String? {
        let folder = profileFolder(for: index)
        // 1. Try Keychain token saved for this profile
        let kcFile = folder.appendingPathComponent("keychain_token.txt")
        if let tokenStr = try? String(contentsOf: kcFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let email = Self.parseEmail(fromKeychainToken: tokenStr) {
            return email
        }

        // 2. Fallback to app_storage.json
        let file = folder.appendingPathComponent("app_storage.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let user = json["agy.onboarding.lastLoginUsername"] as? String, !user.isEmpty {
            return user
        }
        if let user = json["jetski.onboarding.lastLoginUsername"] as? String, !user.isEmpty {
            return user
        }
        return nil
    }

    private func readCurrentEmail() -> String? {
        // 1. Try current Keychain token
        if let token = Self.readCurrentKeychainToken(), let email = Self.parseEmail(fromKeychainToken: token) {
            return email
        }

        // 2. Fallback to current Application Support app_storage.json
        let file = Self.appSupportFolder.appendingPathComponent("app_storage.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let user = json["agy.onboarding.lastLoginUsername"] as? String, !user.isEmpty {
            return user
        }
        if let user = json["jetski.onboarding.lastLoginUsername"] as? String, !user.isEmpty {
            return user
        }
        return nil
    }

    // MARK: - Keychain Helpers

    private static func readCurrentKeychainToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    }

    private static func setKeychainToken(_ token: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["add-generic-password", "-U", "-s", "gemini", "-a", "antigravity", "-w", token]
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func deleteKeychainToken() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["delete-generic-password", "-s", "gemini", "-a", "antigravity"]
        try? proc.run()
        proc.waitUntilExit()
    }

    static func parseEmail(fromKeychainToken tokenStr: String) -> String? {
        var base64Part = tokenStr
        if base64Part.hasPrefix("go-keyring-base64:") {
            base64Part = String(base64Part.dropFirst("go-keyring-base64:".count))
        }
        guard let data = Data(base64Encoded: base64Part),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let email = json["id_token_email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    // MARK: - Process Management

    private static func isProcessRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "/Applications/Antigravity.app/Contents/MacOS/Antigravity"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private static func stopAntigravity() {
        // 1. Graceful quit via AppleScript
        let script = NSAppleScript(source: "tell application \"Antigravity\" to quit")
        script?.executeAndReturnError(nil)

        // 2. Wait up to 2.5s for process to exit
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if !isProcessRunning() { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // 3. Force kill if still running
        if isProcessRunning() {
            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killProc.arguments = ["-9", "-f", "/Applications/Antigravity.app"]
            try? killProc.run()
            killProc.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 4. Kill lingering language_server if present
        let killLs = Process()
        killLs.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killLs.arguments = ["-f", "Contents/Resources/bin/language_server"]
        try? killLs.run()
        killLs.waitUntilExit()

        // 5. Remove Singleton lock files to prevent Chromium re-attaching
        let fm = FileManager.default
        let locks = ["SingletonLock", "SingletonCookie", "SingletonSocket"]
        for lock in locks {
            let lockPath = appSupportFolder.appendingPathComponent(lock)
            try? fm.removeItem(at: lockPath)
        }
    }

    // MARK: - Profile Actions

    /// Saves current active state from Application Support and Keychain to current profile folder.
    func saveCurrentProfile() {
        let fm = FileManager.default
        let folder = profileFolder(for: activeProfileIndex)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Save Application Support files
        for item in Self.authFiles {
            let src = Self.appSupportFolder.appendingPathComponent(item)
            let dst = folder.appendingPathComponent(item)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Save Keychain token
        if let token = Self.readCurrentKeychainToken() {
            let dst = folder.appendingPathComponent("keychain_token.txt")
            try? token.write(to: dst, atomically: true, encoding: .utf8)
        }

        loadState()
    }

    /// Switches between Account 1 and Account 2.
    func switchAccount() {
        let target = activeProfileIndex == 1 ? 2 : 1
        switchTo(profile: target)
    }

    /// Switches specifically to a profile index.
    func switchTo(profile targetIndex: Int) {
        guard !isSwitching else { return }
        isSwitching = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default

            // 1. Terminate Antigravity cleanly so DB and localStorage are fully flushed
            Self.stopAntigravity()

            // 2. Save active profile state (clean flush guaranteed)
            self.saveCurrentProfile()

            // 3. Switch index and restore target profile
            let newIndex = targetIndex
            let targetFolder = self.profileFolder(for: newIndex)

            if fm.fileExists(atPath: targetFolder.path) {
                // Restore Keychain token
                let kcFile = targetFolder.appendingPathComponent("keychain_token.txt")
                if let token = try? String(contentsOf: kcFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                    Self.setKeychainToken(token)
                }

                // Restore Application Support files
                for item in Self.authFiles {
                    let src = targetFolder.appendingPathComponent(item)
                    let dst = Self.appSupportFolder.appendingPathComponent(item)
                    try? fm.removeItem(at: dst)
                    if fm.fileExists(atPath: src.path) {
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
            } else {
                // New profile: remove current auth files and keychain token so it prompts sign-in
                Self.deleteKeychainToken()
                for item in Self.authFiles {
                    let dst = Self.appSupportFolder.appendingPathComponent(item)
                    try? fm.removeItem(at: dst)
                }
            }

            try? "\(newIndex)".write(to: Self.activeFile, atomically: true, encoding: .utf8)

            // 4. Launch Antigravity with proxy environment
            let launchProc = Process()
            launchProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            launchProc.arguments = ["-l", "-c", Self.defaultProxyCommands]
            try? launchProc.run()

            DispatchQueue.main.async {
                self.loadState()
                self.isSwitching = false
                AgentUsageService.shared.pageDidAppear(preview: true)
            }
        }
    }

    /// Relaunches Antigravity with proxy environment.
    func relaunchWithProxy() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            Self.stopAntigravity()
            self.saveCurrentProfile()

            let launchProc = Process()
            launchProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            launchProc.arguments = ["-l", "-c", Self.defaultProxyCommands]
            try? launchProc.run()
        }
    }
}
