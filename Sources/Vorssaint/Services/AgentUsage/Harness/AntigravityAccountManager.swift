// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Combine

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
        "Network Persistent State"
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

        let currEmail = readCurrentAppEmail() ?? ""
        profile1Email = readProfileEmail(index: 1) ?? (activeProfileIndex == 1 ? currEmail : "")
        profile2Email = readProfileEmail(index: 2) ?? (activeProfileIndex == 2 ? currEmail : "")
    }

    func profileFolder(for index: Int) -> URL {
        Self.baseFolder.appendingPathComponent("profile_\(index)", isDirectory: true)
    }

    private func readProfileEmail(index: Int) -> String? {
        let file = profileFolder(for: index).appendingPathComponent("app_storage.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = json["jetski.onboarding.lastLoginUsername"] as? String, !user.isEmpty else {
            return nil
        }
        return user
    }

    private func readCurrentAppEmail() -> String? {
        let file = Self.appSupportFolder.appendingPathComponent("app_storage.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = json["jetski.onboarding.lastLoginUsername"] as? String, !user.isEmpty else {
            return nil
        }
        return user
    }

    /// Saves current active state from Application Support to current profile folder.
    func saveCurrentProfile() {
        let fm = FileManager.default
        let folder = profileFolder(for: activeProfileIndex)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        for item in Self.authFiles {
            let src = Self.appSupportFolder.appendingPathComponent(item)
            let dst = folder.appendingPathComponent(item)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
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

            // 1. Save current profile
            self.saveCurrentProfile()

            // 2. Quit Antigravity
            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killProc.arguments = ["-f", "/Applications/Antigravity.app/Contents/MacOS/Antigravity"]
            try? killProc.run()
            killProc.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.8)

            // 3. Switch index
            let newIndex = targetIndex
            let targetFolder = self.profileFolder(for: newIndex)

            if fm.fileExists(atPath: targetFolder.path) {
                // Restore target profile files
                for item in Self.authFiles {
                    let src = targetFolder.appendingPathComponent(item)
                    let dst = Self.appSupportFolder.appendingPathComponent(item)
                    try? fm.removeItem(at: dst)
                    if fm.fileExists(atPath: src.path) {
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
            } else {
                // New profile: remove current auth files so it prompts sign-in
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
            self.saveCurrentProfile()
            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killProc.arguments = ["-f", "/Applications/Antigravity.app/Contents/MacOS/Antigravity"]
            try? killProc.run()
            killProc.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.8)

            let launchProc = Process()
            launchProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            launchProc.arguments = ["-l", "-c", Self.defaultProxyCommands]
            try? launchProc.run()
        }
    }
}
