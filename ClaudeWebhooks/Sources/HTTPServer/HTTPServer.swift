import Vapor
import Foundation

// MARK: - WebhookHTTPServer

/// A Vapor-based HTTP server that listens on localhost for incoming webhook
/// deliveries and MCP (Model Context Protocol) JSON-RPC requests.
///
/// The server binds exclusively to `127.0.0.1` and is intended to be reached
/// through a Cloudflare tunnel for external traffic, keeping the local attack
/// surface minimal.
final class WebhookHTTPServer {

    // MARK: - Properties

    private let processor: WebhookProcessor
    private let mcpServer: MCPServer

    /// The underlying Vapor application. Created lazily during `start(port:)`.
    private var app: Application?

    /// Simple in-memory rate-limit ledger: IP -> (window start, request count).
    private var rateLimitEntries: [String: RateLimitEntry] = [:]

    /// Lock protecting `rateLimitEntries` from concurrent mutation.
    private let rateLimitLock = NSLock()

    /// Timer that periodically evicts stale rate-limit entries.
    private var cleanupTimer: DispatchSourceTimer?

    /// Maximum number of requests allowed per IP within a single window.
    private let rateLimitMax: Int

    /// Duration of the rate-limit window in seconds.
    private let rateLimitWindowSeconds: TimeInterval = 60

    // MARK: - Types

    /// Tracks how many requests a given IP has made within the current window.
    private struct RateLimitEntry {
        var windowStart: Date
        var count: Int
    }

    // MARK: - Initialization

    /// Creates a new HTTP server.
    ///
    /// - Parameters:
    ///   - processor: The webhook processor that validates and dispatches
    ///     incoming webhook payloads.
    ///   - mcpServer: The MCP server that handles JSON-RPC requests and SSE
    ///     notification streams.
    ///   - rateLimitMax: Maximum requests per IP per minute. Defaults to 100.
    init(processor: WebhookProcessor, mcpServer: MCPServer, rateLimitMax: Int = 100) {
        self.processor = processor
        self.mcpServer = mcpServer
        self.rateLimitMax = rateLimitMax
    }

    deinit {
        cleanupTimer?.cancel()
    }

    // MARK: - Lifecycle

    /// Configures routes and starts the Vapor server on a background thread.
    ///
    /// - Parameter port: The TCP port to listen on. Defaults to `7842`.
    /// - Throws: If the Vapor application fails to start.
    func start(port: Int = 7842) async throws {
        let env = try Environment.detect()
        let app = Application(env)
        self.app = app

        // ── Server configuration ──────────────────────────────────────────
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port

        // Increase the maximum body size to 10 MB to accommodate large
        // webhook payloads (e.g. repository push events with many commits).
        app.routes.defaultMaxBodySize = "10mb"

        // ── Register routes ───────────────────────────────────────────────
        registerRoutes(app)

        // ── Start the rate-limit cleanup timer ────────────────────────────
        startCleanupTimer()

        NSLog("[HTTPServer] Starting on 127.0.0.1:%d", port)

        // Run the server on a detached task so it does not block the caller.
        // Vapor's `run()` is blocking, so we push it off the cooperative
        // thread pool entirely.
        let application = app
        Task.detached(priority: .utility) {
            do {
                try application.run()
            } catch {
                NSLog("[HTTPServer] Server exited with error: %@", String(describing: error))
            }
        }

        // Give the server a moment to bind before returning.
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        NSLog("[HTTPServer] Server started successfully")
    }

    /// Gracefully shuts down the Vapor server and releases resources.
    func stop() {
        NSLog("[HTTPServer] Shutting down")
        cleanupTimer?.cancel()
        cleanupTimer = nil
        app?.shutdown()
        app = nil
        NSLog("[HTTPServer] Shutdown complete")
    }

    // MARK: - Route Registration

    private func registerRoutes(_ app: Application) {
        // Health check
        app.get("health") { [weak self] req -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return self.handleHealthCheck(req)
        }

        // Webhook ingestion
        app.on(.POST, "webhook", ":subscriptionId") { [weak self] req -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return await self.handleWebhook(req)
        }

        // MCP JSON-RPC (request/response)
        app.on(.POST, "mcp") { [weak self] req -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return await self.handleMCPRequest(req)
        }

        // MCP SSE (server-sent events for notifications)
        app.on(.GET, "mcp") { [weak self] req -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return self.handleMCPSSE(req)
        }
    }

    // MARK: - Health Check

    private func handleHealthCheck(_ req: Request) -> Response {
        let body: [String: String] = [
            "status": "ok",
            "server": "ClaudeWebhooks",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: .ok, headers: headers, body: .init(data: data))
        } catch {
            NSLog("[HTTPServer] Failed to encode health response: %@", String(describing: error))
            return Response(status: .internalServerError)
        }
    }

    // MARK: - Webhook Handler

    private func handleWebhook(_ req: Request) async -> Response {
        let clientIP = extractClientIP(from: req)

        // ── Rate limiting ─────────────────────────────────────────────────
        if isRateLimited(ip: clientIP) {
            NSLog("[HTTPServer] Rate limited webhook request from %@", clientIP)
            return makeErrorResponse(
                status: .tooManyRequests,
                message: "Rate limit exceeded. Try again later."
            )
        }

        // ── Extract subscription ID ──────────────────────────────────────
        guard let subscriptionId = req.parameters.get("subscriptionId"), !subscriptionId.isEmpty else {
            NSLog("[HTTPServer] Webhook request missing subscription ID")
            return makeErrorResponse(status: .badRequest, message: "Missing subscription ID.")
        }

        // ── Read body ────────────────────────────────────────────────────
        let bodyData: Data
        if let buffer = req.body.data {
            bodyData = Data(buffer: buffer)
        } else {
            bodyData = Data()
        }

        // ── Collect headers ──────────────────────────────────────────────
        var headers: [String: String] = [:]
        for (name, value) in req.headers {
            headers[name] = value
        }

        NSLog("[HTTPServer] Webhook received for subscription: %@ (%d bytes) from %@",
              subscriptionId, bodyData.count, clientIP)

        // ── Process ──────────────────────────────────────────────────────
        let result = await processor.processWebhook(
            subscriptionId: subscriptionId,
            headers: headers,
            body: bodyData
        )

        return webhookResultToResponse(result)
    }

    /// Maps a `WebhookResult` to the appropriate HTTP response.
    private func webhookResultToResponse(_ result: WebhookResult) -> Response {
        switch result {
        case .accepted:
            return makeJSONResponse(status: .ok, body: ["status": "accepted"])

        case .rejected(let reason):
            NSLog("[HTTPServer] Webhook rejected: %@", reason)
            return makeErrorResponse(status: .forbidden, message: reason)

        case .notFound:
            return makeErrorResponse(status: .notFound, message: "Subscription not found.")

        case .rateLimited:
            return makeErrorResponse(
                status: .tooManyRequests,
                message: "Rate limit exceeded. Try again later."
            )
        }
    }

    // MARK: - MCP JSON-RPC Handler

    private func handleMCPRequest(_ req: Request) async -> Response {
        let clientIP = extractClientIP(from: req)

        // ── Rate limiting ─────────────────────────────────────────────────
        if isRateLimited(ip: clientIP) {
            NSLog("[HTTPServer] Rate limited MCP request from %@", clientIP)
            return makeJSONRPCError(
                code: -32000,
                message: "Rate limit exceeded",
                httpStatus: .tooManyRequests
            )
        }

        // ── Read body ────────────────────────────────────────────────────
        guard let buffer = req.body.data else {
            return makeJSONRPCError(
                code: -32700,
                message: "Parse error: empty request body",
                httpStatus: .badRequest
            )
        }
        let requestData = Data(buffer: buffer)

        if requestData.isEmpty {
            return makeJSONRPCError(
                code: -32700,
                message: "Parse error: empty request body",
                httpStatus: .badRequest
            )
        }

        NSLog("[HTTPServer] MCP request received (%d bytes) from %@",
              requestData.count, clientIP)

        // ── Dispatch to MCP server ───────────────────────────────────────
        do {
            let responseData = try await mcpServer.handleRequest(requestData)

            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(
                status: .ok,
                headers: headers,
                body: .init(data: responseData)
            )
        } catch {
            NSLog("[HTTPServer] MCP request handling failed: %@", String(describing: error))
            return makeJSONRPCError(
                code: -32603,
                message: "Internal error: \(error.localizedDescription)",
                httpStatus: .internalServerError
            )
        }
    }

    // MARK: - MCP SSE Handler

    private func handleMCPSSE(_ req: Request) -> Response {
        let clientIP = extractClientIP(from: req)

        // ── Rate limiting ─────────────────────────────────────────────────
        if isRateLimited(ip: clientIP) {
            NSLog("[HTTPServer] Rate limited SSE connection from %@", clientIP)
            return makeErrorResponse(
                status: .tooManyRequests,
                message: "Rate limit exceeded. Try again later."
            )
        }

        NSLog("[HTTPServer] SSE connection opened from %@", clientIP)

        // Build a streaming response with SSE content type.
        let response = Response(status: .ok)
        response.headers.add(name: .contentType, value: "text/event-stream")
        response.headers.add(name: "Cache-Control", value: "no-cache")
        response.headers.add(name: "Connection", value: "keep-alive")
        response.headers.add(name: "X-Accel-Buffering", value: "no")

        // Create an async stream that the MCP server will push events into.
        let (stream, continuation) = AsyncStream<Data>.makeStream()

        // Register the continuation so the MCP server can send notifications.
        mcpServer.addSSEConnection(continuation)

        // Pipe the async stream into Vapor's response body.
        response.body = .init(asyncStream: { writer in
            // Send an initial comment to confirm the connection is alive.
            // SSE spec: lines beginning with ':' are comments / keep-alives.
            let keepAlive = Data(": connected\n\n".utf8)
            do {
                try await writer.write(.buffer(.init(data: keepAlive)))
            } catch {
                NSLog("[HTTPServer] SSE failed to send keep-alive: %@",
                      String(describing: error))
                continuation.finish()
                return
            }

            // Forward events from the async stream to the HTTP response.
            for await chunk in stream {
                do {
                    try await writer.write(.buffer(.init(data: chunk)))
                } catch {
                    // Client disconnected.
                    NSLog("[HTTPServer] SSE client disconnected: %@",
                          String(describing: error))
                    break
                }
            }

            NSLog("[HTTPServer] SSE connection closed for %@", clientIP)
            try await writer.write(.end)
        })

        return response
    }

    // MARK: - Rate Limiting

    /// Records a request for the given IP and returns `true` if the IP has
    /// exceeded the rate limit.
    private func isRateLimited(ip: String) -> Bool {
        rateLimitLock.lock()
        defer { rateLimitLock.unlock() }

        let now = Date()

        if var entry = rateLimitEntries[ip] {
            // Check whether the current window has expired.
            if now.timeIntervalSince(entry.windowStart) > rateLimitWindowSeconds {
                // Start a new window.
                entry = RateLimitEntry(windowStart: now, count: 1)
                rateLimitEntries[ip] = entry
                return false
            }

            entry.count += 1
            rateLimitEntries[ip] = entry

            if entry.count > rateLimitMax {
                return true
            }
            return false
        } else {
            // First request from this IP.
            rateLimitEntries[ip] = RateLimitEntry(windowStart: now, count: 1)
            return false
        }
    }

    /// Starts a repeating timer that evicts expired rate-limit entries every
    /// 60 seconds, preventing unbounded memory growth.
    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + rateLimitWindowSeconds,
                       repeating: rateLimitWindowSeconds)

        timer.setEventHandler { [weak self] in
            self?.cleanupRateLimitEntries()
        }

        timer.resume()
        cleanupTimer = timer
    }

    /// Removes rate-limit entries whose window has expired.
    private func cleanupRateLimitEntries() {
        rateLimitLock.lock()
        defer { rateLimitLock.unlock() }

        let now = Date()
        let expiredKeys = rateLimitEntries.compactMap { key, entry -> String? in
            if now.timeIntervalSince(entry.windowStart) > rateLimitWindowSeconds {
                return key
            }
            return nil
        }

        for key in expiredKeys {
            rateLimitEntries.removeValue(forKey: key)
        }

        if !expiredKeys.isEmpty {
            NSLog("[HTTPServer] Cleaned up %d expired rate-limit entries", expiredKeys.count)
        }
    }

    // MARK: - Helpers

    /// Extracts the client IP address from the request.
    ///
    /// Checks `X-Forwarded-For` first (for traffic arriving via reverse
    /// proxy / Cloudflare tunnel), then falls back to the socket peer address.
    private func extractClientIP(from req: Request) -> String {
        // X-Forwarded-For may contain a comma-separated list; take the first.
        if let forwarded = req.headers.first(name: "X-Forwarded-For") {
            let firstIP = forwarded.split(separator: ",").first.map(String.init) ?? forwarded
            return firstIP.trimmingCharacters(in: .whitespaces)
        }

        // CF-Connecting-IP is set by Cloudflare specifically.
        if let cfIP = req.headers.first(name: "CF-Connecting-IP") {
            return cfIP.trimmingCharacters(in: .whitespaces)
        }

        return req.remoteAddress?.description ?? "unknown"
    }

    /// Builds a JSON response with a simple key-value body.
    private func makeJSONResponse(status: HTTPResponseStatus, body: [String: String]) -> Response {
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: status, headers: headers, body: .init(data: data))
        } catch {
            NSLog("[HTTPServer] Failed to encode JSON response: %@", String(describing: error))
            return Response(status: .internalServerError)
        }
    }

    /// Builds a JSON error response.
    private func makeErrorResponse(status: HTTPResponseStatus, message: String) -> Response {
        return makeJSONResponse(status: status, body: [
            "error": message
        ])
    }

    /// Builds a JSON-RPC 2.0 error response.
    ///
    /// When the request `id` is unknown (e.g. a parse error), the `id` field
    /// is set to `null` per the JSON-RPC specification.
    private func makeJSONRPCError(code: Int, message: String, httpStatus: HTTPResponseStatus) -> Response {
        let errorBody: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ],
            "id": NSNull()
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: errorBody)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: httpStatus, headers: headers, body: .init(data: data))
        } catch {
            NSLog("[HTTPServer] Failed to encode JSON-RPC error: %@", String(describing: error))
            return Response(status: .internalServerError)
        }
    }
}
