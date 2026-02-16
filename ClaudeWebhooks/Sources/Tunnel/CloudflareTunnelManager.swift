import Foundation
import Security
import Combine

// MARK: - TunnelStatus

enum TunnelStatus: String {
    case active
    case inactive
    case starting
    case error
}

// MARK: - TunnelError

enum TunnelError: Error {
    case cloudflaredNotFound
    case configurationFailed(String)
    case startFailed(String)
    case keychainError(String)
}

// MARK: - CloudflareTunnelManager

class CloudflareTunnelManager: ObservableObject {

    // MARK: Published Properties

    @Published var status: TunnelStatus = .inactive
    @Published var publicURL: String?

    var isActive: Bool { status == .active }

    // MARK: Private Properties

    private var tunnelProcess: Process?
    private var healthCheckTimer: Timer?
    private let configDir: String
    private var consecutiveHealthFailures = 0
    private let maxHealthFailures = 3
    private let keychainService = "com.claude.webhooks"
    private var tunnelID: String?

    // MARK: Initialization

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.configDir = "\(home)/.config/cloudflared/"
    }

    // MARK: - Public Methods

    /// Whether a tunnel has been configured (config.yml exists).
    var isConfigured: Bool {
        FileManager.default.fileExists(atPath: "\(configDir)config.yml")
    }

    func startTunnel() async throws {
        let configPath = "\(configDir)config.yml"
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw TunnelError.configurationFailed(
                "No tunnel configured. Run /setup-tunnel in Claude Code."
            )
        }

        let cloudflaredPath = try locateCloudflared()

        // Read tunnel config to construct the public URL
        if let configContents = try? String(contentsOfFile: configPath, encoding: .utf8) {
            if let tid = parseTunnelID(from: configContents) {
                tunnelID = tid
            }
            // Prefer hostname from config (DNS route) over tunnel ID URL
            if let hostname = parseHostname(from: configContents) {
                await MainActor.run {
                    self.publicURL = "https://\(hostname)"
                }
            }
        }

        await MainActor.run {
            self.status = .starting
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredPath)
        process.arguments = ["tunnel", "--config", configPath, "run"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Handle unexpected termination
        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.status == .active {
                    NSLog("[CloudflareTunnel] Process terminated unexpectedly (code %d). Restarting...",
                          proc.terminationStatus)
                    self.status = .error
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        try? await self.restartTunnel()
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            await MainActor.run {
                self.status = .error
            }
            throw TunnelError.startFailed("Failed to launch cloudflared: \(error.localizedDescription)")
        }

        self.tunnelProcess = process
        monitorProcessOutput(process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        // Wait briefly for connections to register, then mark active
        try await Task.sleep(nanoseconds: 5_000_000_000)
        await MainActor.run {
            if self.status == .starting {
                self.status = .active
            }
            self.startHealthCheck()
        }
    }

    /// Start a quick tunnel without configuration (temporary trycloudflare.com URL).
    func startQuickTunnel() async throws {
        let cloudflaredPath = try locateCloudflared()

        await MainActor.run {
            self.status = .starting
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cloudflaredPath)
        process.arguments = ["tunnel", "--url", "http://localhost:7842"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.status == .active {
                    NSLog("[CloudflareTunnel] Quick tunnel terminated unexpectedly (code %d).",
                          proc.terminationStatus)
                    self.status = .error
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        try? await self.startQuickTunnel()
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            await MainActor.run {
                self.status = .error
            }
            throw TunnelError.startFailed(
                "Failed to launch quick tunnel: \(error.localizedDescription)"
            )
        }

        self.tunnelProcess = process
        monitorProcessOutput(process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        // Wait for the URL to be parsed from stderr
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if publicURL != nil { break }
        }

        await MainActor.run {
            if self.publicURL != nil {
                self.status = .active
            } else {
                self.status = .error
            }
            self.startHealthCheck()
        }
    }

    /// Stop the running tunnel gracefully.
    func stopTunnel() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        consecutiveHealthFailures = 0

        guard let process = tunnelProcess, process.isRunning else {
            status = .inactive
            publicURL = nil
            tunnelProcess = nil
            return
        }

        // Set inactive BEFORE terminating so the terminationHandler
        // doesn't treat this as an unexpected crash and auto-restart.
        status = .inactive
        publicURL = nil

        // Send SIGTERM for graceful shutdown
        process.terminate()

        // Wait up to 5 seconds, then force kill
        DispatchQueue.global().async { [weak self] in
            let deadline = Date().addingTimeInterval(5.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
            if process.isRunning {
                NSLog("[CloudflareTunnel] Process did not exit gracefully. Sending SIGKILL.")
                kill(process.processIdentifier, SIGKILL)
            }
            DispatchQueue.main.async {
                self?.status = .inactive
                self?.publicURL = nil
                self?.tunnelProcess = nil
            }
        }
    }

    /// Restart the tunnel by stopping then starting again.
    func restartTunnel() async throws {
        stopTunnel()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await startTunnel()
    }

    // MARK: - Private Methods

    /// Locate the cloudflared binary, downloading it automatically if not found.
    private func locateCloudflared() throws -> String {
        // Check bundled location first
        let bundledPath = bundledCloudflaredPath()
        if FileManager.default.fileExists(atPath: bundledPath) {
            return bundledPath
        }

        // Check system paths
        let knownPath = "/usr/local/bin/cloudflared"
        if FileManager.default.fileExists(atPath: knownPath) {
            return knownPath
        }

        // Fall back to `which cloudflared`
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["cloudflared"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice

        try? whichProcess.run()
        whichProcess.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return path
        }

        // Not found anywhere — download it
        NSLog("[CloudflareTunnel] cloudflared not found, downloading...")
        let downloaded = try downloadCloudflared()
        return downloaded
    }

    /// Path where we store our own copy of cloudflared.
    private func bundledCloudflaredPath() -> String {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeWebhooks/bin")
        return appSupport.appendingPathComponent("cloudflared").path
    }

    /// Download cloudflared from GitHub releases.
    private func downloadCloudflared() throws -> String {
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #else
        arch = "amd64"
        #endif

        let urlString = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-\(arch).tgz"
        guard let url = URL(string: urlString) else {
            throw TunnelError.configurationFailed("Invalid download URL")
        }

        let binDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeWebhooks/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let tgzPath = binDir.appendingPathComponent("cloudflared.tgz")
        let destPath = binDir.appendingPathComponent("cloudflared")

        // Download
        NSLog("[CloudflareTunnel] Downloading from %@", urlString)
        let data = try Data(contentsOf: url)
        try data.write(to: tgzPath)

        // Extract
        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["-xzf", tgzPath.path, "-C", binDir.path]
        tarProcess.standardError = FileHandle.nullDevice
        try tarProcess.run()
        tarProcess.waitUntilExit()

        guard tarProcess.terminationStatus == 0 else {
            throw TunnelError.configurationFailed("Failed to extract cloudflared")
        }

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destPath.path
        )

        // Clean up tgz
        try? FileManager.default.removeItem(at: tgzPath)

        guard FileManager.default.fileExists(atPath: destPath.path) else {
            throw TunnelError.configurationFailed("cloudflared binary not found after extraction")
        }

        NSLog("[CloudflareTunnel] Downloaded cloudflared to %@", destPath.path)
        return destPath.path
    }

    /// Parse a hostname from cloudflared config.yml (e.g. "hostname: webhooks.example.com").
    private func parseHostname(from config: String) -> String? {
        let pattern = #"hostname:\s*(.+)"#
        guard let range = config.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = String(config[range])
        // Extract the value after "hostname:"
        let parts = match.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Parse a UUID-style tunnel ID from cloudflared output.
    private func parseTunnelID(from output: String) -> String? {
        let pattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        guard let range = output.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }

    /// Monitor stdout and stderr of the tunnel process for the public URL and log output.
    private func monitorProcessOutput(_ process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        let quickTunnelPattern = #"https://[a-zA-Z0-9\-]+\.trycloudflare\.com"#
        let tunnelIDPattern = #"tunnelID=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#

        // Monitor stderr (cloudflared writes most info here)
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            NSLog("[CloudflareTunnel:stderr] %@", line.trimmingCharacters(in: .newlines))

            // Quick tunnel URL
            if let range = line.range(of: quickTunnelPattern, options: .regularExpression) {
                let url = String(line[range])
                DispatchQueue.main.async {
                    self?.publicURL = url
                    if self?.status == .starting {
                        self?.status = .active
                    }
                    NSLog("[CloudflareTunnel] Public URL discovered: %@", url)
                }
            }

            // Named tunnel ID from "Starting tunnel tunnelID=..."
            if self?.publicURL == nil,
               let match = line.range(of: tunnelIDPattern, options: .regularExpression),
               let tid = self?.parseTunnelID(from: String(line[match])) {
                DispatchQueue.main.async {
                    self?.tunnelID = tid
                    self?.publicURL = "https://\(tid).cfargotunnel.com"
                    NSLog("[CloudflareTunnel] Public URL from tunnel ID: %@", self?.publicURL ?? "")
                }
            }
        }

        // Monitor stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            NSLog("[CloudflareTunnel:stdout] %@", line.trimmingCharacters(in: .newlines))

            if let range = line.range(of: quickTunnelPattern, options: .regularExpression) {
                let url = String(line[range])
                DispatchQueue.main.async {
                    self?.publicURL = url
                    if self?.status == .starting {
                        self?.status = .active
                    }
                }
            }
        }
    }

    /// Periodically check the tunnel health by pinging the public URL.
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        consecutiveHealthFailures = 0

        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) {
            [weak self] _ in
            guard let self = self, let urlString = self.publicURL,
                  let url = URL(string: urlString) else { return }

            let task = URLSession.shared.dataTask(with: url) { [weak self] _, response, error in
                guard let self = self else { return }
                let httpResponse = response as? HTTPURLResponse
                let success = error == nil && httpResponse != nil

                DispatchQueue.main.async {
                    if success {
                        self.consecutiveHealthFailures = 0
                        if self.status == .error {
                            self.status = .active
                        }
                    } else {
                        self.consecutiveHealthFailures += 1
                        NSLog("[CloudflareTunnel] Health check failed (%d/%d): %@",
                              self.consecutiveHealthFailures,
                              self.maxHealthFailures,
                              error?.localizedDescription ?? "no response")

                        if self.consecutiveHealthFailures >= self.maxHealthFailures {
                            NSLog("[CloudflareTunnel] Max health failures reached. Restarting tunnel.")
                            self.status = .error
                            Task {
                                try? await self.restartTunnel()
                            }
                        }
                    }
                }
            }
            task.resume()
        }
    }

    // MARK: - Keychain Helpers

    /// Save a value to the macOS Keychain under the given key.
    private func saveToKeychain(key: String, value: String) throws {
        // Remove any existing item first
        deleteFromKeychain(key: key)

        guard let data = value.data(using: .utf8) else {
            throw TunnelError.keychainError("Failed to encode value for key: \(key)")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TunnelError.keychainError(
                "Failed to save to Keychain (key: \(key), status: \(status))"
            )
        }
    }

    /// Load a value from the macOS Keychain for the given key.
    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete an item from the macOS Keychain for the given key.
    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
