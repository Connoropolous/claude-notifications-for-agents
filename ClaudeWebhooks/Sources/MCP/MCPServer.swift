import Foundation

// MARK: - AnyCodableValue

/// A type-erased JSON value that supports encoding and decoding arbitrary
/// JSON structures. Used throughout the MCP JSON-RPC layer where the schema
/// is dynamic (tool parameters, results, etc.).
enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        if let arrayValue = try? container.decode([AnyCodableValue].self) {
            self = .array(arrayValue)
            return
        }
        if let objectValue = try? container.decode([String: AnyCodableValue].self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.typeMismatch(
            AnyCodableValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unable to decode AnyCodableValue"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    // MARK: Convenience accessors

    /// Returns the underlying `String` value, or `nil` if this is not `.string`.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Returns the underlying `Bool` value, or `nil` if this is not `.bool`.
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Returns the underlying `Int` value, or `nil` if this is not `.int`.
    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// Returns the underlying dictionary, or `nil` if this is not `.object`.
    var objectValue: [String: AnyCodableValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: AnyCodableValue?
    let method: String
    let params: [String: AnyCodableValue]?
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: AnyCodableValue?
    let result: AnyCodableValue?
    let error: JSONRPCError?
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
}

struct MCPNotification: Codable {
    let method: String
    let params: [String: AnyCodableValue]?
}

// MARK: - MCPServer

/// Implements the Model Context Protocol (MCP) server that exposes webhook
/// management tools to Claude Code over JSON-RPC 2.0.
///
/// The server is designed to be driven by an HTTP layer -- callers pass raw
/// `Data` in and get `Data` back. SSE connections are tracked separately so
/// the server can push asynchronous notifications (e.g. when a new webhook
/// event arrives).
final class MCPServer {

    // MARK: - Dependencies

    private let database: DatabaseManager
    private let tunnelManager: CloudflareTunnelManager
    private let sessionManager: SessionManager

    // MARK: - SSE Connection Tracking

    private struct SSEConnection {
        let id: UUID
        let continuation: AsyncStream<Data>.Continuation
    }

    /// All active SSE connections. Protected by `connectionLock`.
    private var sseConnections: [SSEConnection] = []

    /// Lock guarding `sseConnections` for thread-safe mutation.
    private let connectionLock = NSLock()

    // MARK: - Constants

    private static let protocolVersion = "2024-11-05"
    private static let serverName = "claude-webhooks"
    private static let serverVersion = "1.0.0"
    private static let localBaseURL = "http://127.0.0.1:7842"

    // MARK: - Initialization

    init(database: DatabaseManager, tunnelManager: CloudflareTunnelManager, sessionManager: SessionManager) {
        self.database = database
        self.tunnelManager = tunnelManager
        self.sessionManager = sessionManager
    }

    // MARK: - Public API

    /// Processes an incoming MCP JSON-RPC request and returns the serialized
    /// JSON-RPC response.
    ///
    /// - Parameter data: The raw JSON bytes of the incoming request.
    /// - Returns: The raw JSON bytes of the response.
    /// - Throws: Only if JSON serialization of the response itself fails
    ///   (application-level errors are returned as JSON-RPC error objects).
    func handleRequest(_ data: Data) async throws -> Data {
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            return try encode(errorResponse(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)"))
        }

        guard request.jsonrpc == "2.0" else {
            return try encode(errorResponse(id: request.id, code: -32600, message: "Invalid Request: unsupported JSON-RPC version"))
        }

        let response: JSONRPCResponse
        do {
            response = try await dispatch(request)
        } catch {
            response = errorResponse(id: request.id, code: -32603, message: "Internal error: \(error.localizedDescription)")
        }

        return try encode(response)
    }

    /// Registers an SSE connection so that the server can push notifications
    /// to it. Returns the UUID assigned to the connection, which the caller
    /// should pass to `removeSSEConnection(_:)` when the client disconnects.
    @discardableResult
    func addSSEConnection(_ continuation: AsyncStream<Data>.Continuation) -> UUID {
        let id = UUID()
        connectionLock.lock()
        sseConnections.append(SSEConnection(id: id, continuation: continuation))
        connectionLock.unlock()
        NSLog("[MCPServer] SSE connection added (id: %@, total: %d)", id.uuidString, sseConnections.count)
        return id
    }

    /// Removes a previously registered SSE connection.
    func removeSSEConnection(_ id: UUID) {
        connectionLock.lock()
        sseConnections.removeAll { $0.id == id }
        connectionLock.unlock()
        NSLog("[MCPServer] SSE connection removed (id: %@)", id.uuidString)
    }

    // MARK: - Notification Broadcasting

    /// Broadcasts an MCP notification to every active SSE connection.
    ///
    /// Connections that fail to accept the write are silently removed.
    private func sendNotification(_ notification: MCPNotification) {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(notification)
        } catch {
            NSLog("[MCPServer] Failed to encode notification: %@", String(describing: error))
            return
        }

        // SSE wire format: "data: <json>\n\n"
        guard var message = "data: ".data(using: .utf8) else { return }
        message.append(payload)
        message.append(contentsOf: [0x0A, 0x0A]) // two newlines

        connectionLock.lock()
        let connections = sseConnections
        connectionLock.unlock()

        for connection in connections {
            connection.continuation.yield(message)
        }
    }

    // MARK: - Request Dispatch

    /// Routes a parsed JSON-RPC request to the appropriate handler.
    private func dispatch(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)

        case "notifications/initialized":
            // Client acknowledgment -- no response needed for notifications,
            // but since we received it as a request we return an empty result.
            return successResponse(id: request.id, result: .object([:]))

        case "tools/list":
            return handleToolsList(request)

        case "tools/call":
            return try await handleToolsCall(request)

        default:
            return errorResponse(id: request.id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    // MARK: - initialize

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: AnyCodableValue = .object([
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(Self.serverVersion)
            ]),
            "protocolVersion": .string(Self.protocolVersion)
        ])

        return successResponse(id: request.id, result: result)
    }

    // MARK: - tools/list

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let tools: AnyCodableValue = .object([
            "tools": .array([
                toolDefinition(
                    name: "create_subscription",
                    description: "Create a new webhook subscription. Returns a unique webhook URL that external services can POST to.",
                    properties: [
                        "session_id": propertyDef(type: "string", description: "The Claude Code session ID to deliver events to"),
                        "hmac_secret": propertyDef(type: "string", description: "Optional HMAC secret for signature verification"),
                        "hmac_header": propertyDef(type: "string", description: "Optional header name containing the HMAC signature (e.g. X-Hub-Signature-256)"),
                        "name": propertyDef(type: "string", description: "Optional human-readable name for this subscription"),
                        "service": propertyDef(type: "string", description: "Optional service type (github, linear, stripe, custom)"),
                        "events": propertyDef(type: "array", description: "Optional list of event types to subscribe to"),
                        "prompt": propertyDef(type: "string", description: "Prompt text prepended to the payload when delivering events to the session. Frames the event for Claude."),
                        "jq_filter": propertyDef(type: "string", description: "jq expression applied to the raw payload BEFORE processing. Acts as a gate: if the result is false/null/empty the event is silently dropped. Use select() to filter in matching events, e.g. 'select(.action == \"opened\")'. Runs before summary_filter."),
                        "summary_filter": propertyDef(type: "string", description: "jq expression to extract a compact summary from the raw payload for injection. Runs AFTER jq_filter. The full payload is always stored and retrievable via get_event_payload. E.g. '{action: .action, title: .pull_request.title}'"),
                        "one_shot": propertyDef(type: "boolean", description: "If true, auto-delete subscription after first delivery")
                    ],
                    required: ["session_id"]
                ),
                toolDefinition(
                    name: "list_subscriptions",
                    description: "List webhook subscriptions. If session_id is provided, returns only subscriptions for that session; otherwise returns all.",
                    properties: [
                        "session_id": propertyDef(type: "string", description: "Optional session ID to filter by")
                    ],
                    required: []
                ),
                toolDefinition(
                    name: "delete_subscription",
                    description: "Delete a webhook subscription by ID.",
                    properties: [
                        "subscription_id": propertyDef(type: "string", description: "The subscription ID to delete")
                    ],
                    required: ["subscription_id"]
                ),
                toolDefinition(
                    name: "update_subscription",
                    description: "Update an existing webhook subscription. Only provided fields are changed. Processing order: jq_filter runs first on the raw payload to decide accept/reject, then summary_filter runs to extract a compact summary for injection.",
                    properties: [
                        "subscription_id": propertyDef(type: "string", description: "The subscription ID to update"),
                        "jq_filter": propertyDef(type: "string", description: "jq expression applied to the raw payload BEFORE processing. Acts as a gate: if the result is false/null/empty the event is silently dropped (not injected, not logged). Use select() expressions to filter in matching events, e.g. 'select(.action == \"opened\")'. Runs before summary_filter."),
                        "summary_filter": propertyDef(type: "string", description: "jq expression to extract a compact summary from the raw payload for injection. Runs AFTER jq_filter. The full payload is always stored and retrievable via get_event_payload. E.g. '{action: .action, title: .pull_request.title}'"),
                        "status": propertyDef(type: "string", description: "New status (active or paused)")
                    ],
                    required: ["subscription_id"]
                ),
                toolDefinition(
                    name: "start_tunnel",
                    description: "Start the persistent Cloudflare tunnel. Requires /setup-tunnel to have been run first (creates config.yml). Returns the public URL once active.",
                    properties: [:],
                    required: []
                ),
                toolDefinition(
                    name: "stop_tunnel",
                    description: "Stop the running Cloudflare tunnel.",
                    properties: [:],
                    required: []
                ),
                toolDefinition(
                    name: "start_quick_tunnel",
                    description: "Start a temporary Cloudflare quick tunnel (no auth needed). WARNING: The URL changes every restart, breaking any registered webhooks. Only for quick testing.",
                    properties: [:],
                    required: []
                ),
                toolDefinition(
                    name: "get_tunnel_status",
                    description: "Get the current status of the Cloudflare tunnel.",
                    properties: [:],
                    required: []
                ),
                toolDefinition(
                    name: "get_public_webhook_url",
                    description: "Get the public webhook URL for a subscription. Returns the tunnel URL if active, otherwise the local URL.",
                    properties: [
                        "subscription_id": propertyDef(type: "string", description: "The subscription ID")
                    ],
                    required: ["subscription_id"]
                ),
                toolDefinition(
                    name: "get_event_payload",
                    description: "Retrieve the full untruncated payload for a previously received webhook event by its event ID.",
                    properties: [
                        "event_id": propertyDef(type: "string", description: "The event ID from the webhook-event XML tag")
                    ],
                    required: ["event_id"]
                )
            ])
        ])

        return successResponse(id: request.id, result: tools)
    }

    // MARK: - tools/call

    private func handleToolsCall(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        guard let params = request.params,
              let toolName = params["name"]?.stringValue else {
            return errorResponse(id: request.id, code: -32602, message: "Invalid params: missing tool name")
        }

        let arguments = params["arguments"]?.objectValue ?? [:]

        let result: AnyCodableValue
        do {
            switch toolName {
            case "create_subscription":
                result = try handleCreateSubscription(arguments)
            case "list_subscriptions":
                result = try handleListSubscriptions(arguments)
            case "delete_subscription":
                result = try handleDeleteSubscription(arguments)
            case "update_subscription":
                result = try handleUpdateSubscription(arguments)
            case "start_tunnel":
                result = try await handleStartTunnel()
            case "stop_tunnel":
                result = handleStopTunnel()
            case "start_quick_tunnel":
                result = try await handleStartQuickTunnel()
            case "get_tunnel_status":
                result = handleGetTunnelStatus()
            case "get_public_webhook_url":
                result = try handleGetPublicWebhookURL(arguments)
            case "get_event_payload":
                result = try handleGetEventPayload(arguments)
            default:
                return errorResponse(id: request.id, code: -32602, message: "Unknown tool: \(toolName)")
            }
        } catch {
            let errorText = "Error executing \(toolName): \(error.localizedDescription)"
            return successResponse(id: request.id, result: toolResult(errorText, isError: true))
        }

        return successResponse(id: request.id, result: result)
    }

    // MARK: - Tool Implementations

    private func handleCreateSubscription(_ arguments: [String: AnyCodableValue]) throws -> AnyCodableValue {
        guard let sessionId = arguments["session_id"]?.stringValue else {
            throw MCPError.missingParameter("session_id")
        }

        let secretToken = arguments["hmac_secret"]?.stringValue
        let hmacHeader = arguments["hmac_header"]?.stringValue
        let name = arguments["name"]?.stringValue
        let service = arguments["service"]?.stringValue
        let prompt = arguments["prompt"]?.stringValue
        let summaryFilter = arguments["summary_filter"]?.stringValue
        let oneShot = arguments["one_shot"]?.boolValue ?? false
        let jqFilter = arguments["jq_filter"]?.stringValue

        let subscriptionId = UUID().uuidString
        let webhookUrl = "\(Self.localBaseURL)/webhook/\(subscriptionId)"

        let subscription = try database.createSubscription(
            id: subscriptionId,
            sessionId: sessionId,
            webhookUrl: webhookUrl,
            secretToken: secretToken,
            hmacHeader: hmacHeader,
            name: name,
            service: service,
            prompt: prompt,
            summaryFilter: summaryFilter,
            oneShot: oneShot,
            jqFilter: jqFilter
        )

        var responseText = """
            Subscription created successfully.
            ID: \(subscription.id)
            Session: \(subscription.sessionId)
            Local webhook URL: \(webhookUrl)
            """

        if let publicURL = tunnelManager.publicURL {
            let publicWebhookURL = "\(publicURL)/webhook/\(subscription.id)"
            responseText += "\nPublic webhook URL: \(publicWebhookURL)"
        }

        if let token = secretToken {
            responseText += "\nSecret token: configured (\(token.prefix(4))...)"
        }
        if let sf = summaryFilter {
            responseText += "\nSummary filter: \(sf)"
        }
        if let filter = jqFilter {
            responseText += "\njq filter: \(filter)"
        }

        return toolResult(responseText)
    }

    private func handleListSubscriptions(_ arguments: [String: AnyCodableValue]) throws -> AnyCodableValue {
        let subscriptions: [Subscription]

        if let sessionId = arguments["session_id"]?.stringValue {
            subscriptions = try database.getSubscriptions(forSession: sessionId)
        } else {
            subscriptions = try database.getAllSubscriptions()
        }

        if subscriptions.isEmpty {
            return toolResult("No subscriptions found.")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let jsonData = try encoder.encode(subscriptions)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

        return toolResult("Found \(subscriptions.count) subscription(s):\n\(jsonString)")
    }

    private func handleDeleteSubscription(_ arguments: [String: AnyCodableValue]) throws -> AnyCodableValue {
        guard let subscriptionId = arguments["subscription_id"]?.stringValue else {
            throw MCPError.missingParameter("subscription_id")
        }

        // Verify the subscription exists before deleting.
        guard let _ = try database.getSubscription(id: subscriptionId) else {
            throw MCPError.notFound("Subscription '\(subscriptionId)' not found")
        }

        try database.deleteSubscription(id: subscriptionId)

        return toolResult("Subscription '\(subscriptionId)' deleted successfully.")
    }

    private func handleUpdateSubscription(_ arguments: [String: AnyCodableValue]) throws -> AnyCodableValue {
        guard let subscriptionId = arguments["subscription_id"]?.stringValue else {
            throw MCPError.missingParameter("subscription_id")
        }

        guard var subscription = try database.getSubscription(id: subscriptionId) else {
            throw MCPError.notFound("Subscription '\(subscriptionId)' not found")
        }

        var changes: [String] = []

        if let jqFilter = arguments["jq_filter"]?.stringValue {
            subscription.jqFilter = jqFilter
            changes.append("jq_filter -> \(jqFilter)")
        }
        if let sf = arguments["summary_filter"]?.stringValue {
            subscription.summaryFilter = sf
            changes.append("summary_filter -> \(sf)")
        }
        if let status = arguments["status"]?.stringValue {
            guard status == "active" || status == "paused" else {
                throw MCPError.invalidParameter("status must be 'active' or 'paused'")
            }
            subscription.status = status
            changes.append("status -> \(status)")
        }

        if changes.isEmpty {
            return toolResult("No changes specified for subscription '\(subscriptionId)'.")
        }

        try database.updateSubscription(subscription)

        return toolResult("Subscription '\(subscriptionId)' updated:\n- \(changes.joined(separator: "\n- "))")
    }

    private func handleStartTunnel() async throws -> AnyCodableValue {
        if tunnelManager.isActive {
            var responseText = "Tunnel is already active."
            if let publicURL = tunnelManager.publicURL {
                responseText += "\nPublic URL: \(publicURL)"
            }
            return toolResult(responseText)
        }

        try await tunnelManager.startTunnel()

        // Wait a moment for the URL to be parsed
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        var responseText = "Tunnel started."
        if let publicURL = tunnelManager.publicURL {
            responseText += "\nPublic URL: \(publicURL)"
        } else {
            responseText += "\nPublic URL not yet available. Call get_tunnel_status in a few seconds."
        }

        return toolResult(responseText)
    }

    private func handleStopTunnel() -> AnyCodableValue {
        tunnelManager.stopTunnel()
        return toolResult("Tunnel stopped.")
    }

    private func handleStartQuickTunnel() async throws -> AnyCodableValue {
        if tunnelManager.isActive {
            var responseText = "Tunnel is already active."
            if let publicURL = tunnelManager.publicURL {
                responseText += "\nPublic URL: \(publicURL)"
            }
            return toolResult(responseText)
        }

        try await tunnelManager.startQuickTunnel()

        var responseText = "Quick tunnel started. WARNING: This URL is temporary and will change on restart. Any webhooks registered with this URL will break. Use configure_tunnel with an API token for a stable URL."
        if let publicURL = tunnelManager.publicURL {
            responseText += "\nPublic URL: \(publicURL)"
        } else {
            responseText += "\nTunnel started but public URL not yet available. Call get_tunnel_status in a few seconds."
        }

        return toolResult(responseText)
    }

    private func handleGetTunnelStatus() -> AnyCodableValue {
        let isActive = tunnelManager.isActive
        var responseText = "Tunnel status: \(isActive ? "active" : "inactive")"

        if let publicURL = tunnelManager.publicURL {
            responseText += "\nPublic URL: \(publicURL)"
        } else {
            responseText += "\nPublic URL: not available (tunnel is not active)"
        }

        return toolResult(responseText)
    }

    private func handleGetPublicWebhookURL(_ arguments: [String: AnyCodableValue]) throws -> AnyCodableValue {
        guard let subscriptionId = arguments["subscription_id"]?.stringValue else {
            throw MCPError.missingParameter("subscription_id")
        }

        // Verify the subscription exists.
        guard let _ = try database.getSubscription(id: subscriptionId) else {
            throw MCPError.notFound("Subscription '\(subscriptionId)' not found")
        }

        let localURL = "\(Self.localBaseURL)/webhook/\(subscriptionId)"

        if let publicBaseURL = tunnelManager.publicURL {
            let publicURL = "\(publicBaseURL)/webhook/\(subscriptionId)"
            return toolResult("Public webhook URL: \(publicURL)\nLocal webhook URL: \(localURL)")
        } else {
            return toolResult("Local webhook URL: \(localURL)\nNote: No tunnel is active. Configure a Cloudflare tunnel to get a public URL.")
        }
    }

    private func handleGetEventPayload(_ arguments: [String: AnyCodableValue]) throws -> AnyCodableValue {
        guard let eventId = arguments["event_id"]?.stringValue else {
            throw MCPError.missingParameter("event_id")
        }

        guard let event = try database.getEvent(id: eventId) else {
            throw MCPError.notFound("Event '\(eventId)' not found")
        }

        return toolResult(event.payload ?? "{}")
    }

    // MARK: - Response Builders

    private func successResponse(id: AnyCodableValue?, result: AnyCodableValue) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    private func errorResponse(id: AnyCodableValue?, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: JSONRPCError(code: code, message: message))
    }

    /// Wraps a text string in the MCP tool result format:
    /// `{"content": [{"type": "text", "text": "..."}]}`
    private func toolResult(_ text: String, isError: Bool = false) -> AnyCodableValue {
        var result: [String: AnyCodableValue] = [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
        ]

        if isError {
            result["isError"] = .bool(true)
        }

        return .object(result)
    }

    // MARK: - Tool Definition Helpers

    /// Builds a JSON Schema-style tool definition for the `tools/list` response.
    private func toolDefinition(
        name: String,
        description: String,
        properties: [String: AnyCodableValue],
        required: [String]
    ) -> AnyCodableValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) })
            ])
        ])
    }

    /// Builds a JSON Schema property definition.
    private func propertyDef(type: String, description: String) -> AnyCodableValue {
        .object([
            "type": .string(type),
            "description": .string(description)
        ])
    }

    // MARK: - Encoding

    private func encode(_ response: JSONRPCResponse) throws -> Data {
        try JSONEncoder().encode(response)
    }
}

// MARK: - MCPError

/// Domain-specific errors raised during MCP tool execution. These are
/// caught by the `tools/call` handler and returned as MCP tool error
/// results (not JSON-RPC errors) so the client can display them.
enum MCPError: LocalizedError {
    case missingParameter(String)
    case invalidParameter(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            return "Missing required parameter: \(name)"
        case .invalidParameter(let detail):
            return "Invalid parameter: \(detail)"
        case .notFound(let detail):
            return detail
        }
    }
}
