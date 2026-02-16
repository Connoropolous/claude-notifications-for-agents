import Foundation
import Combine

/// Monitors active Claude Code sessions by watching the Unix socket directory.
/// Sessions are identified by .sock files in ~/.claude/sockets/.
public class SessionManager: ObservableObject {

    // MARK: - Published Properties

    @Published public var activeSessions: Set<String> = []

    // MARK: - Private Properties

    private let socketDirectory: String
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var onSessionResumed: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.claudewebhooks.sessionmanager", qos: .utility)
    private var pollingTimer: DispatchSourceTimer?

    // MARK: - Initialization

    public init(socketDirectory: String? = nil) {
        if let socketDirectory = socketDirectory {
            self.socketDirectory = socketDirectory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.socketDirectory = "\(home)/.claude/sockets"
        }
    }

    deinit {
        stopWatching()
    }

    // MARK: - Public Methods

    /// Begin monitoring the socket directory for session changes.
    public func startWatching() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureSocketDirectoryExists()
            self.scanSessions()
            self.setupDirectoryMonitor()
        }
    }

    /// Stop all monitoring and clean up resources.
    public func stopWatching() {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.pollingTimer?.cancel()
            self.pollingTimer = nil

            self.directoryMonitor?.cancel()
            self.directoryMonitor = nil

            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }

            DispatchQueue.main.async {
                self.activeSessions = []
            }

            NSLog("[SessionManager] Stopped watching socket directory")
        }
    }

    /// Scan the socket directory and update the set of active sessions.
    public func scanSessions() {
        let fileManager = FileManager.default
        var discoveredIds = Set<String>()

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: socketDirectory)
            for filename in contents where filename.hasSuffix(".sock") {
                let sessionId = String(filename.dropLast(5)) // remove ".sock"
                let fullPath = "\(socketDirectory)/\(filename)"
                if verifySocket(path: fullPath) {
                    discoveredIds.insert(sessionId)
                }
            }
        } catch {
            NSLog("[SessionManager] Failed to list socket directory: %@", error.localizedDescription)
            return
        }

        let previousSessions = activeSessions
        let newSessions = discoveredIds.subtracting(previousSessions)
        let removedSessions = previousSessions.subtracting(discoveredIds)

        for sessionId in newSessions {
            NSLog("[SessionManager] Session appeared: %@", sessionId)
            onSessionResumed?(sessionId)
        }

        for sessionId in removedSessions {
            NSLog("[SessionManager] Session disappeared: %@", sessionId)
        }

        if discoveredIds != previousSessions {
            DispatchQueue.main.async { [weak self] in
                self?.activeSessions = discoveredIds
            }
        }
    }

    /// Check whether a specific session is currently active and connectable.
    public func isSessionActive(_ sessionId: String) -> Bool {
        let path = "\(socketDirectory)/\(sessionId).sock"
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }
        return verifySocket(path: path)
    }

    /// Register a callback invoked whenever a previously-absent session becomes active.
    public func setOnSessionResumed(_ handler: @escaping (String) -> Void) {
        queue.async { [weak self] in
            self?.onSessionResumed = handler
        }
    }

    /// Returns a sorted array of all currently active session IDs.
    public func getActiveSessionIds() -> [String] {
        return activeSessions.sorted()
    }

    // MARK: - Private Methods

    /// Ensure the socket directory exists, creating it if necessary.
    private func ensureSocketDirectoryExists() {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: socketDirectory, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                NSLog("[SessionManager] WARNING: %@ exists but is not a directory", socketDirectory)
            }
            return
        }

        do {
            try fileManager.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true)
            NSLog("[SessionManager] WARNING: Socket directory did not exist, created: %@", socketDirectory)
        } catch {
            NSLog("[SessionManager] Failed to create socket directory: %@", error.localizedDescription)
        }
    }

    /// Set up GCD file system monitoring on the socket directory.
    private func setupDirectoryMonitor() {
        fileDescriptor = Darwin.open(socketDirectory, O_EVTONLY)

        guard fileDescriptor >= 0 else {
            NSLog("[SessionManager] Failed to open directory for monitoring, falling back to polling")
            startPollingFallback()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            NSLog("[SessionManager] Directory change detected, scanning sessions")
            self.scanSessions()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        directoryMonitor = source

        NSLog("[SessionManager] Started watching socket directory: %@", socketDirectory)
    }

    /// Fall back to periodic polling if directory monitoring is unavailable.
    private func startPollingFallback() {
        NSLog("[SessionManager] Starting polling fallback (every 5 seconds)")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.scanSessions()
        }
        timer.resume()
        pollingTimer = timer
    }

    /// Verify that a Unix socket at the given path is connectable.
    /// Returns false for stale socket files left behind by crashed sessions.
    private func verifySocket(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("[SessionManager] Socket path too long: %@", path)
            return false
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, addrLen)
            }
        }

        return result == 0
    }
}
