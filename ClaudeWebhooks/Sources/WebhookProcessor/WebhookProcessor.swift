import Foundation
import CryptoKit

// MARK: - Result

enum WebhookResult {
    case accepted
    case rejected(reason: String)
    case notFound
    case rateLimited
}

// MARK: - WebhookProcessor

final class WebhookProcessor {

    // MARK: - Dependencies

    private let database: DatabaseManager
    private let sessionManager: SessionManager

    // MARK: - Constants

    private static let jqPath = "/usr/bin/jq"

    // MARK: - Initialization

    init(database: DatabaseManager, sessionManager: SessionManager) {
        self.database = database
        self.sessionManager = sessionManager
    }

    // MARK: - Public API

    func processWebhook(
        subscriptionId: String,
        headers: [String: String],
        body: Data
    ) async -> WebhookResult {

        // 1. Lookup subscription
        guard var subscription = try? database.getSubscription(id: subscriptionId) else {
            NSLog("[WebhookProcessor] Subscription not found: %@", subscriptionId)
            return .notFound
        }

        NSLog("[WebhookProcessor] Found subscription: %@ (status=%@, service=%@, hasSecret=%d, hmacHeader=%@)",
              subscriptionId,
              subscription.status,
              subscription.service ?? "nil",
              subscription.secretToken?.isEmpty == false ? 1 : 0,
              subscription.hmacHeader ?? "nil")

        if subscription.status == "paused" {
            NSLog("[WebhookProcessor] Subscription %@ is paused, rejecting", subscriptionId)
            return .rejected(reason: "paused")
        }

        // 2. HMAC signature verification (Swift-native, no scripts)
        if let secret = subscription.secretToken, !secret.isEmpty {
            let headerName = subscription.hmacHeader ?? "X-Hub-Signature-256"
            // Case-insensitive header lookup
            let signatureHeader = headers[headerName]
                ?? headers[headerName.lowercased()]
                ?? headers.first(where: { $0.key.lowercased() == headerName.lowercased() })?.value

            NSLog("[WebhookProcessor] HMAC check: headerName=%@, signaturePresent=%d, availableHeaders=%@",
                  headerName,
                  signatureHeader != nil ? 1 : 0,
                  headers.keys.joined(separator: ", "))

            guard let signatureHeader, !signatureHeader.isEmpty else {
                NSLog("[WebhookProcessor] HMAC rejected: missing signature header '%@'", headerName)
                logEvent(subscriptionId: subscriptionId, payload: body, result: "rejected", injected: false)
                return .rejected(reason: "missing_signature")
            }

            if !verifySignature(body: body, secret: secret, signatureHeader: signatureHeader) {
                NSLog("[WebhookProcessor] HMAC rejected: invalid signature")
                logEvent(subscriptionId: subscriptionId, payload: body, result: "rejected", injected: false)
                return .rejected(reason: "invalid_signature")
            }

            NSLog("[WebhookProcessor] HMAC verification passed")
        } else {
            NSLog("[WebhookProcessor] No HMAC secret configured, skipping verification")
        }

        // 3. Apply jq event filter (if set) — only matching events pass through
        if let jqFilter = subscription.jqFilter, !jqFilter.isEmpty {
            NSLog("[WebhookProcessor] Running jq event filter: %@", jqFilter)
            let filterResult = try? await runJq(filter: jqFilter, payload: body)
            if filterResult == nil {
                NSLog("[WebhookProcessor] Event filtered out by jq_filter, skipping")
                return .accepted
            }
            NSLog("[WebhookProcessor] Event passed jq_filter")
        }

        // 5. Log the full payload (stored for get_event_payload retrieval)
        let eventId = logEvent(
            subscriptionId: subscriptionId,
            payload: body,
            result: "accepted",
            injected: false
        )
        NSLog("[WebhookProcessor] Logged event: %@", eventId)

        // 6. Summarize payload via jq summary_filter (if set)
        var summaryString: String
        if let summaryFilter = subscription.summaryFilter, !summaryFilter.isEmpty {
            NSLog("[WebhookProcessor] Running jq summary filter: %@", summaryFilter)
            if let result = try? await runJq(filter: summaryFilter, payload: body) {
                summaryString = String(data: result, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "{}"
                NSLog("[WebhookProcessor] jq summary produced %d chars", summaryString.count)
            } else {
                NSLog("[WebhookProcessor] jq summary filter failed, falling back to truncation")
                summaryString = truncatePayload(body, maxLength: 500)
            }
        } else {
            NSLog("[WebhookProcessor] No summary filter, using truncated payload")
            summaryString = truncatePayload(body, maxLength: 2000)
        }

        // 7. Build XML-framed message for injection
        let service = subscription.service ?? "webhook"
        let prompt = subscription.prompt ?? "A \(service) event was received. Review and take appropriate action."

        let framedMessage = """
            <webhook-event service="\(service)" event-id="\(eventId)">
            \(prompt)
            <payload>
            \(summaryString)
            </payload>
            To see the full untruncated payload, use the get_event_payload tool with event_id "\(eventId)".
            If this event is too noisy, or the summary needs tuning, use update_subscription to adjust the summary_filter (jq expression) or jq_filter (to suppress unwanted events entirely) for subscription "\(subscriptionId)".
            </webhook-event>
            """

        // 6. Inject into session
        NSLog("[WebhookProcessor] Injecting into session: %@", subscription.sessionId)
        let injected: Bool
        do {
            injected = try await SocketInjector.inject(
                sessionId: subscription.sessionId,
                payload: Data(framedMessage.utf8)
            )
            NSLog("[WebhookProcessor] Injection result: %@", injected ? "success" : "failed (no error)")
        } catch {
            NSLog("[WebhookProcessor] Injection error: %@", error.localizedDescription)
            injected = false
        }

        if !injected {
            NSLog("[WebhookProcessor] Queuing event for later delivery")
            try? database.queueEvent(
                subscriptionId: subscriptionId,
                sessionId: subscription.sessionId,
                payload: Data(framedMessage.utf8)
            )
        } else {
            subscription.eventCount += 1
            try? database.updateSubscription(subscription)
            NSLog("[WebhookProcessor] Event count incremented to %d", subscription.eventCount)
        }

        // Update the event log with injection status
        if injected {
            try? database.markEventInjected(id: eventId)
        }

        return .accepted
    }

    /// Deliver queued events when a session becomes active.
    func deliverQueuedEvents(sessionId: String) async {
        let queuedEvents: [QueuedEvent]
        do {
            queuedEvents = try database.getQueuedEvents(sessionId: sessionId)
        } catch {
            NSLog("[WebhookProcessor] Failed to get queued events: %@", error.localizedDescription)
            return
        }

        for event in queuedEvents {
            let delivered: Bool
            do {
                delivered = try await SocketInjector.inject(
                    sessionId: sessionId,
                    payload: event.payload
                )
            } catch {
                delivered = false
            }

            if delivered {
                try? database.removeQueuedEvent(id: event.id)

                if var subscription = try? database.getSubscription(id: event.subscriptionId) {
                    subscription.eventCount += 1
                    try? database.updateSubscription(subscription)
                }
            }
        }
    }

    // MARK: - HMAC Signature Verification

    private func verifySignature(body: Data, secret: String, signatureHeader: String) -> Bool {
        guard let secretData = secret.data(using: .utf8) else {
            return false
        }

        let symmetricKey = SymmetricKey(data: secretData)
        let computedMAC = HMAC<SHA256>.authenticationCode(for: body, using: symmetricKey)
        let computedHex = computedMAC.map { String(format: "%02x", $0) }.joined()

        // Strip optional "sha256=" prefix (GitHub convention)
        let receivedHex: String
        if signatureHeader.lowercased().hasPrefix("sha256=") {
            receivedHex = String(signatureHeader.dropFirst(7))
        } else {
            receivedHex = signatureHeader
        }

        guard let computedData = computedHex.data(using: .utf8),
              let receivedData = receivedHex.lowercased().data(using: .utf8) else {
            return false
        }

        return timingSafeEqual(computedData, receivedData)
    }

    private func timingSafeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (lhs, rhs) in zip(a, b) {
            result |= lhs ^ rhs
        }
        return result == 0
    }

    // MARK: - jq

    private func runJq(filter: String, payload: Data) async throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.jqPath)
        process.arguments = [filter]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let lock = NSLock()

            func resumeOnce(with result: Result<Data?, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            process.terminationHandler = { _ in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

                guard process.terminationStatus == 0 else {
                    resumeOnce(with: .success(nil))
                    return
                }

                let outputString = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if outputString.isEmpty || outputString == "false" || outputString == "null" {
                    resumeOnce(with: .success(nil))
                    return
                }

                resumeOnce(with: .success(outputData))
            }

            do {
                try process.run()
                inputPipe.fileHandleForWriting.write(payload)
                inputPipe.fileHandleForWriting.closeFile()
            } catch {
                resumeOnce(with: .failure(error))
            }
        }
    }

    // MARK: - Helpers

    private func truncatePayload(_ data: Data, maxLength: Int) -> String {
        let full = String(data: data, encoding: .utf8) ?? "{}"
        if full.count <= maxLength { return full }
        return String(full.prefix(maxLength)) + "\n... (truncated, use get_event_payload for full data)"
    }

    @discardableResult
    private func logEvent(
        subscriptionId: String,
        payload: Data,
        result: String,
        injected: Bool
    ) -> String {
        let payloadString = String(data: payload, encoding: .utf8)
        let event = try? database.logEvent(
            subscriptionId: subscriptionId,
            payload: payloadString,
            result: result,
            injected: injected
        )
        return event?.id ?? UUID().uuidString
    }
}
