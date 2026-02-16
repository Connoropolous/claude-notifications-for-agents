import Foundation
import Combine
import GRDB

// MARK: - Records

struct Subscription: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "subscriptions"

    let id: String
    var sessionId: String
    var webhookUrl: String
    var secretToken: String?
    var hmacHeader: String?
    var name: String?
    var service: String?
    var prompt: String?
    var summaryFilter: String?
    var oneShot: Bool
    var jqFilter: String?
    var status: String
    let createdAt: Date
    var eventCount: Int
}

struct Event: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "events"

    let id: String
    let subscriptionId: String
    let receivedAt: Date
    let payload: String?
    let verificationResult: String?
    var injected: Bool
}

struct QueuedEvent: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "queued_events"

    let id: String
    let subscriptionId: String
    let sessionId: String
    let payload: Data
    let queuedAt: Date
}

// MARK: - DatabaseManager

class DatabaseManager: ObservableObject {
    private var dbPool: DatabasePool?

    /// Fires whenever subscriptions are created, updated, or deleted.
    let subscriptionsChanged = PassthroughSubject<Void, Never>()

    // MARK: - Initialization

    func initialize() throws {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupportURL.appendingPathComponent("ClaudeWebhooks")

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let dbPath = directoryURL.appendingPathComponent("subscriptions.db").path
        dbPool = try DatabasePool(path: dbPath)

        try runMigrations()
    }

    private func runMigrations() throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            try db.create(table: "subscriptions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull()
                t.column("webhookUrl", .text).notNull()
                t.column("secretToken", .text)
                t.column("verificationScriptPath", .text)
                t.column("jqFilter", .text)
                t.column("status", .text).defaults(to: "active")
                t.column("createdAt", .double).notNull()
                t.column("eventCount", .integer).defaults(to: 0)
            }

            try db.create(table: "events", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("subscriptionId", .text).notNull()
                    .references("subscriptions", onDelete: .cascade)
                t.column("receivedAt", .double).notNull()
                t.column("payload", .text)
                t.column("verificationResult", .text)
                t.column("injected", .boolean).defaults(to: false)
            }
        }

        migrator.registerMigration("v2_createQueuedEvents") { db in
            try db.create(table: "queued_events", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("subscriptionId", .text).notNull()
                    .references("subscriptions", onDelete: .cascade)
                t.column("sessionId", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("queuedAt", .double).notNull()
            }
        }

        migrator.registerMigration("v3_addSubscriptionFields") { db in
            try db.alter(table: "subscriptions") { t in
                t.add(column: "hmacHeader", .text)
                t.add(column: "name", .text)
                t.add(column: "service", .text)
                t.add(column: "prompt", .text)
                t.add(column: "summaryFilter", .text)
                t.add(column: "oneShot", .boolean).defaults(to: false)
            }
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - Subscription CRUD

    func createSubscription(
        id: String = UUID().uuidString,
        sessionId: String,
        webhookUrl: String,
        secretToken: String?,
        hmacHeader: String?,
        name: String?,
        service: String?,
        prompt: String?,
        summaryFilter: String?,
        oneShot: Bool = false,
        jqFilter: String?
    ) throws -> Subscription {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        let subscription = Subscription(
            id: id,
            sessionId: sessionId,
            webhookUrl: webhookUrl,
            secretToken: secretToken,
            hmacHeader: hmacHeader,
            name: name,
            service: service,
            prompt: prompt,
            summaryFilter: summaryFilter,
            oneShot: oneShot,
            jqFilter: jqFilter,
            status: "active",
            createdAt: Date(),
            eventCount: 0
        )

        try dbPool.write { db in
            try subscription.insert(db)
        }

        subscriptionsChanged.send()
        return subscription
    }

    func getSubscription(id: String) throws -> Subscription? {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        return try dbPool.read { db in
            try Subscription.fetchOne(db, key: id)
        }
    }

    func getAllSubscriptions() throws -> [Subscription] {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        return try dbPool.read { db in
            try Subscription.fetchAll(db)
        }
    }

    func getSubscriptions(forSession sessionId: String) throws -> [Subscription] {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        return try dbPool.read { db in
            try Subscription
                .filter(Column("sessionId") == sessionId)
                .fetchAll(db)
        }
    }

    func updateSubscription(_ subscription: Subscription) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbPool.write { db in
            try subscription.update(db)
        }
        subscriptionsChanged.send()
    }

    func deleteSubscription(id: String) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbPool.write { db in
            _ = try Subscription.deleteOne(db, key: id)
        }
        subscriptionsChanged.send()
    }

    func pauseSubscription(id: String) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbPool.write { db in
            if var subscription = try Subscription.fetchOne(db, key: id) {
                subscription.status = "paused"
                try subscription.update(db)
            }
        }
        subscriptionsChanged.send()
    }

    func resumeSubscription(id: String) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbPool.write { db in
            if var subscription = try Subscription.fetchOne(db, key: id) {
                subscription.status = "active"
                try subscription.update(db)
            }
        }
        subscriptionsChanged.send()
    }

    func incrementEventCount(subscriptionId: String) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbPool.write { db in
            if var subscription = try Subscription.fetchOne(db, key: subscriptionId) {
                subscription.eventCount += 1
                try subscription.update(db)
            }
        }
        subscriptionsChanged.send()
    }

    // MARK: - Event Methods

    func logEvent(
        subscriptionId: String,
        payload: String?,
        result: String?,
        injected: Bool
    ) throws -> Event {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        let event = Event(
            id: UUID().uuidString,
            subscriptionId: subscriptionId,
            receivedAt: Date(),
            payload: payload,
            verificationResult: result,
            injected: injected
        )

        try dbPool.write { db in
            try event.insert(db)
        }

        return event
    }

    func getEvent(id: String) throws -> Event? {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        return try dbPool.read { db in
            try Event.fetchOne(db, key: id)
        }
    }

    func getEvents(subscriptionId: String, limit: Int = 50) throws -> [Event] {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        return try dbPool.read { db in
            try Event
                .filter(Column("subscriptionId") == subscriptionId)
                .order(Column("receivedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func getUninjectedEvents(subscriptionId: String) throws -> [Event] {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        return try dbPool.read { db in
            try Event
                .filter(Column("subscriptionId") == subscriptionId)
                .filter(Column("injected") == false)
                .order(Column("receivedAt").asc)
                .fetchAll(db)
        }
    }

    func markEventInjected(id: String) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbPool.write { db in
            if var event = try Event.fetchOne(db, key: id) {
                event.injected = true
                try event.update(db)
            }
        }
    }

    func cleanupOldEvents(olderThan days: Int = 7) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)

        try dbPool.write { db in
            _ = try Event
                .filter(Column("receivedAt") < cutoffDate)
                .deleteAll(db)
        }
    }

    // MARK: - Queued Events

    func queueEvent(subscriptionId: String, sessionId: String, payload: Data) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        let queuedEvent = QueuedEvent(
            id: UUID().uuidString,
            subscriptionId: subscriptionId,
            sessionId: sessionId,
            payload: payload,
            queuedAt: Date()
        )

        try dbPool.write { db in
            try queuedEvent.insert(db)
        }
    }

    func getQueuedEvents(sessionId: String) throws -> [QueuedEvent] {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        return try dbPool.read { db in
            try QueuedEvent
                .filter(Column("sessionId") == sessionId)
                .order(Column("queuedAt").asc)
                .fetchAll(db)
        }
    }

    func removeQueuedEvent(id: String) throws {
        guard let dbPool = dbPool else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbPool.write { db in
            _ = try QueuedEvent.deleteOne(db, key: id)
        }
    }

    // MARK: - Observation

    func observeSubscriptions(onChange: @escaping ([Subscription]) -> Void) -> DatabaseCancellable {
        guard let dbPool = dbPool else {
            fatalError("Database not initialized. Call initialize() first.")
        }

        let observation = ValueObservation.tracking { db in
            try Subscription.fetchAll(db)
        }

        return observation.start(
            in: dbPool,
            onError: { error in
                print("Subscription observation error: \(error)")
            },
            onChange: onChange
        )
    }
}

// MARK: - Error

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
