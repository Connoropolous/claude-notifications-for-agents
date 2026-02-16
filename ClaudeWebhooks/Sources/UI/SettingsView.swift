import SwiftUI
import Foundation

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var tunnelManager: CloudflareTunnelManager
    let database: DatabaseManager

    // MARK: - Tunnel State

    @State private var tunnelActionInProgress = false
    @State private var tunnelErrorMessage: String?

    // MARK: - Settings (UserDefaults-backed)

    @AppStorage("rateLimitPerMinute") private var rateLimitPerMinute: Int = 100
    @AppStorage("eventRetentionDays") private var eventRetentionDays: Int = 7
    @AppStorage("autoStartTunnel") private var autoStartTunnel: Bool = false
    @AppStorage("showNotifications") private var showNotifications: Bool = true

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    tunnelSection
                    Divider()
                    webhookSettingsSection
                }
                .padding(20)
            }

            Divider()
            footerSection
        }
        .frame(width: 420, height: 460)
    }

    // MARK: - Cloudflare Tunnel Section

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloudflare Tunnel")
                .font(.headline)

            // Status row
            HStack(spacing: 8) {
                Circle()
                    .fill(tunnelStatusColor)
                    .frame(width: 10, height: 10)

                Text(tunnelStatusText)
                    .font(.subheadline)

                Spacer()
            }

            // Public URL row
            if let publicURL = tunnelManager.publicURL {
                HStack(spacing: 8) {
                    Text(publicURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button(action: { copyToClipboard(publicURL) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy public URL")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            // Tunnel control buttons
            HStack(spacing: 10) {
                if tunnelManager.isActive {
                    Button(action: stopTunnel) {
                        Label("Stop Tunnel", systemImage: "stop.fill")
                    }
                    .disabled(tunnelActionInProgress)

                    Button(action: restartTunnel) {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .disabled(tunnelActionInProgress)
                } else if tunnelManager.isConfigured {
                    Button(action: startTunnel) {
                        Label("Start Tunnel", systemImage: "play.fill")
                    }
                    .disabled(tunnelActionInProgress)
                } else {
                    Text("Run /setup-tunnel in Claude Code to configure.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if tunnelActionInProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            // Error display
            if let errorMessage = tunnelErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Webhook Settings Section

    private var webhookSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Webhook Settings")
                .font(.headline)

            // Rate limit
            HStack {
                Text("Rate limit:")
                    .font(.subheadline)
                Spacer()
                TextField("", value: $rateLimitPerMinute, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("req/min")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Event retention
            HStack {
                Text("Event retention:")
                    .font(.subheadline)
                Spacer()
                TextField("", value: $eventRetentionDays, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Toggles
            Toggle("Auto-start tunnel on launch", isOn: $autoStartTunnel)
                .font(.subheadline)

            Toggle("Show desktop notifications", isOn: $showNotifications)
                .font(.subheadline)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Spacer()

            Button("Close") {
                closeWindow()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Tunnel Status Helpers

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
            return "Active"
        case .inactive:
            return "Inactive"
        case .starting:
            return "Starting..."
        case .error:
            return "Error"
        }
    }

    // MARK: - Actions

    private func startTunnel() {
        tunnelActionInProgress = true
        tunnelErrorMessage = nil

        Task {
            do {
                try await tunnelManager.startTunnel()
            } catch {
                tunnelErrorMessage = "Failed to start tunnel: \(error.localizedDescription)"
            }
            tunnelActionInProgress = false
        }
    }

    private func stopTunnel() {
        tunnelManager.stopTunnel()
    }

    private func restartTunnel() {
        tunnelActionInProgress = true
        tunnelErrorMessage = nil

        Task {
            tunnelManager.stopTunnel()
            // Brief pause to allow the process to fully terminate
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                try await tunnelManager.startTunnel()
            } catch {
                tunnelErrorMessage = "Failed to restart tunnel: \(error.localizedDescription)"
            }
            tunnelActionInProgress = false
        }
    }

    private func closeWindow() {
        // Close the hosting window
        NSApp.keyWindow?.close()
    }

    // MARK: - Helpers

    private func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
