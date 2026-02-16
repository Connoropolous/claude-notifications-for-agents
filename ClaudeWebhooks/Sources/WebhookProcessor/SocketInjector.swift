import Foundation
import Darwin

// MARK: - Error Types

enum SocketInjectorError: Error {
    case sessionNotFound(sessionId: String)
    case connectionFailed(String)
    case sendFailed(String)
    case socketCreationFailed
}

// MARK: - SocketInjector

/// Injects messages into Claude Code sessions via Unix domain sockets.
///
/// Each Claude Code / Agent SDK session runs a socket server at
/// `~/.claude/sockets/{sessionId}.sock` that accepts newline-delimited
/// messages. Each line is parsed as JSON with the following protocol:
///
///   - JSON string:  `"plain text"` → treated as a prompt
///   - JSON object:  `{"value": "...", "mode": "prompt"}` → value is the
///     prompt text, mode controls how it's queued
///   - Plain text:   `hello` → falls back to raw prompt
///
/// Newlines *inside* a JSON string value are escaped by the serializer,
/// so the entire message stays on a single line as required.
///
/// Reference implementation (socket reader):
/// https://github.com/Connoropolous/claude-notifications-for-agents
struct SocketInjector {

    private static let socketDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/sockets"
    }()

    // MARK: - Helper Methods

    /// Constructs the socket path for a given session ID.
    static func socketPath(for sessionId: String) -> String {
        return "\(socketDirectory)/\(sessionId).sock"
    }

    /// Checks whether a socket file exists for the given session ID.
    static func isSessionActive(sessionId: String) -> Bool {
        let path = socketPath(for: sessionId)
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Injection

    /// Injects a message into the Claude Code session identified by `sessionId`.
    ///
    /// The payload is wrapped in `{"value": "...", "mode": "prompt"}` so that
    /// the socket reader (see struct doc) delivers it as a single prompt,
    /// even if the content contains newlines.
    ///
    /// - Parameters:
    ///   - sessionId: The target session identifier.
    ///   - payload: The message content to inject (UTF-8 text, typically XML-framed).
    /// - Returns: `true` on successful delivery.
    /// - Throws: `SocketInjectorError` on failure.
    static func inject(sessionId: String, payload: Data) async throws -> Bool {
        let path = socketPath(for: sessionId)

        // 1. Verify the socket file exists.
        guard FileManager.default.fileExists(atPath: path) else {
            throw SocketInjectorError.sessionNotFound(sessionId: sessionId)
        }

        // 2. Validate path length for sockaddr_un (max 104 bytes on macOS including null terminator).
        guard path.utf8.count < 104 else {
            throw SocketInjectorError.connectionFailed(
                "Socket path exceeds maximum length of 103 characters: \(path)"
            )
        }

        // 3. Create the Unix domain socket.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketInjectorError.socketCreationFailed
        }
        defer {
            close(fd)
        }

        // 4. Set up sockaddr_un and connect.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // Copy the path into sun_path.
        let pathBytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: UInt8.self, capacity: 104) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
                dest[pathBytes.count] = 0 // null terminator
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            let errorMessage = String(cString: strerror(errno))
            throw SocketInjectorError.connectionFailed(
                "Failed to connect to socket at \(path): \(errorMessage)"
            )
        }

        // 5. Wrap in JSON object for the socket protocol.
        //    The socket reader parses each newline-delimited line as JSON.
        //    Sending {"value": "...", "mode": "prompt"} keeps newlines
        //    inside the JSON string escaped, so the whole message stays
        //    on one line.
        let payloadString = String(data: payload, encoding: .utf8) ?? ""
        let wrapper: [String: String] = ["value": payloadString, "mode": "prompt"]
        var messageData = try JSONSerialization.data(withJSONObject: wrapper)
        messageData.append(0x0A) // newline delimiter

        // 6. Send the message.
        let bytesSent = messageData.withUnsafeBytes { bufferPtr in
            Darwin.send(fd, bufferPtr.baseAddress, bufferPtr.count, 0)
        }

        guard bytesSent == messageData.count else {
            let errorMessage = String(cString: strerror(errno))
            throw SocketInjectorError.sendFailed(
                "Failed to send data (sent \(bytesSent)/\(messageData.count) bytes): \(errorMessage)"
            )
        }

        NSLog("[SocketInjector] Successfully injected payload into session %@", sessionId)
        return true
    }

    // MARK: - Retry Logic

    /// Attempts to inject a payload with automatic retries on failure.
    ///
    /// - Parameters:
    ///   - sessionId: The target session identifier.
    ///   - payload: The raw JSON payload data from the webhook.
    ///   - maxRetries: Maximum number of retry attempts (default 3).
    ///   - delay: Delay in seconds between retry attempts (default 1.0).
    /// - Returns: `true` if injection eventually succeeded, `false` if all retries exhausted.
    static func injectWithRetry(
        sessionId: String,
        payload: Data,
        maxRetries: Int = 3,
        delay: TimeInterval = 1.0
    ) async -> Bool {
        for attempt in 1...maxRetries {
            do {
                let success = try await inject(sessionId: sessionId, payload: payload)
                return success
            } catch {
                NSLog(
                    "[SocketInjector] Attempt %d/%d failed for session %@: %@",
                    attempt, maxRetries, sessionId, error.localizedDescription
                )
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        NSLog(
            "[SocketInjector] All %d retries exhausted for session %@",
            maxRetries, sessionId
        )
        return false
    }
}
