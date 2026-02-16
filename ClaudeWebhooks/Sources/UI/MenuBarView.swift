import SwiftUI
import Foundation

// MARK: - MenuBarView

struct MenuBarView: View {
    @ObservedObject var database: DatabaseManager
    @ObservedObject var tunnelManager: CloudflareTunnelManager
    let sessionManager: SessionManager

    // MARK: - State

    @State private var subscriptions: [Subscription] = []
    @State private var showDeleteConfirmation = false
    @State private var subscriptionToDelete: Subscription?
    @State private var showEditSheet = false
    @State private var subscriptionToEdit: Subscription?
    @State private var editJqFilter: String = ""

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            subscriptionListSection
            Divider()
            tunnelStatusSection
            Divider()
            footerSection
        }
        .frame(width: 350)
        .onAppear(perform: loadSubscriptions)
        .onReceive(database.subscriptionsChanged) { _ in
            loadSubscriptions()
        }
        .alert("Delete Subscription", isPresented: $showDeleteConfirmation) {
            deleteConfirmationAlert
        } message: {
            Text("This will permanently remove the subscription and all associated events. This action cannot be undone.")
        }
        .sheet(isPresented: $showEditSheet) {
            editSubscriptionSheet
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("Webhook Subscriptions")
                .font(.headline)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Open Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Subscription List

    private var subscriptionListSection: some View {
        Group {
            if subscriptions.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(subscriptions, id: \.id) { subscription in
                            subscriptionRow(subscription)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No Subscriptions")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Create a subscription via MCP to start receiving webhooks.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func subscriptionRow(_ subscription: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: status dot + service name
            HStack(spacing: 8) {
                statusDot(for: subscription)

                VStack(alignment: .leading, spacing: 2) {
                    Text(serviceName(from: subscription))
                        .font(.system(.body, design: .default))
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(truncatedSessionId(subscription.sessionId))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(subscription.eventCount) events")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Action buttons row
            HStack(spacing: 8) {
                Spacer()

                Button(action: { togglePause(subscription) }) {
                    Label(
                        subscription.status == "paused" ? "Resume" : "Pause",
                        systemImage: subscription.status == "paused" ? "play.fill" : "pause.fill"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(subscription.status == "paused" ? "Resume subscription" : "Pause subscription")

                Button(action: { beginEdit(subscription) }) {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Edit subscription")

                Button(action: { confirmDelete(subscription) }) {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .help("Delete subscription")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Status Dot

    private func statusDot(for subscription: Subscription) -> some View {
        let color: Color = {
            switch subscription.status {
            case "active":
                let sessionActive = sessionManager.isSessionActive(subscription.sessionId)
                return sessionActive ? .green : .red
            case "paused":
                return .red
            default:
                return .yellow
            }
        }()

        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    // MARK: - Tunnel Status

    private var tunnelStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tunnelStatusColor)
                    .frame(width: 8, height: 8)

                Text("Tunnel: \(tunnelStatusText)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }

            if let publicURL = tunnelManager.publicURL {
                HStack(spacing: 6) {
                    Text(truncatedURL(publicURL))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button(action: { copyToClipboard(publicURL) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy tunnel URL")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var tunnelStatusColor: Color {
        switch tunnelManager.status {
        case .active:
            return .green
        case .inactive:
            return .red
        case .starting:
            return .yellow
        case .error:
            return .red
        }
    }

    private var tunnelStatusText: String {
        switch tunnelManager.status {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .starting:
            return "starting"
        case .error:
            return "error"
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Delete Confirmation Alert

    @ViewBuilder
    private var deleteConfirmationAlert: some View {
        Button("Cancel", role: .cancel) {
            subscriptionToDelete = nil
        }
        Button("Delete", role: .destructive) {
            if let subscription = subscriptionToDelete {
                performDelete(subscription)
            }
        }
    }

    // MARK: - Edit Sheet

    private var editSubscriptionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Subscription")
                .font(.headline)

            if let subscription = subscriptionToEdit {
                Text("ID: \(truncatedSessionId(subscription.id))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("jq Filter")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextField("e.g. .action == \"opened\"", text: $editJqFilter)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showEditSheet = false
                    subscriptionToEdit = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveEdit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Actions

    private func loadSubscriptions() {
        do {
            subscriptions = try database.getAllSubscriptions()
        } catch {
            NSLog("[MenuBarView] Failed to load subscriptions: %@", error.localizedDescription)
        }
    }

    private func togglePause(_ subscription: Subscription) {
        do {
            if subscription.status == "paused" {
                try database.resumeSubscription(id: subscription.id)
            } else {
                try database.pauseSubscription(id: subscription.id)
            }
            loadSubscriptions()
        } catch {
            NSLog("[MenuBarView] Failed to toggle pause: %@", error.localizedDescription)
        }
    }

    private func confirmDelete(_ subscription: Subscription) {
        subscriptionToDelete = subscription
        showDeleteConfirmation = true
    }

    private func performDelete(_ subscription: Subscription) {
        do {
            try database.deleteSubscription(id: subscription.id)
            subscriptionToDelete = nil
            loadSubscriptions()
        } catch {
            NSLog("[MenuBarView] Failed to delete subscription: %@", error.localizedDescription)
        }
    }

    private func beginEdit(_ subscription: Subscription) {
        subscriptionToEdit = subscription
        editJqFilter = subscription.jqFilter ?? ""
        showEditSheet = true
    }

    private func saveEdit() {
        guard var subscription = subscriptionToEdit else { return }
        subscription.jqFilter = editJqFilter.isEmpty ? nil : editJqFilter

        do {
            try database.updateSubscription(subscription)
            showEditSheet = false
            subscriptionToEdit = nil
            loadSubscriptions()
        } catch {
            NSLog("[MenuBarView] Failed to save subscription edit: %@", error.localizedDescription)
        }
    }

    private func openSettings() {
        let settingsView = SettingsView(
            tunnelManager: tunnelManager,
            database: database
        )

        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Claude Webhooks Settings"
        window.setContentSize(NSSize(width: 420, height: 480))
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    private func serviceName(from subscription: Subscription) -> String {
        if let name = subscription.name, !name.isEmpty {
            return name
        }
        if let service = subscription.service, !service.isEmpty {
            return service
        }
        return String(subscription.id.prefix(12))
    }

    private func truncatedSessionId(_ sessionId: String) -> String {
        if sessionId.count > 8 {
            return String(sessionId.prefix(8)) + "..."
        }
        return sessionId
    }

    private func truncatedURL(_ url: String) -> String {
        if url.count > 40 {
            return String(url.prefix(37)) + "..."
        }
        return url
    }

    private func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
