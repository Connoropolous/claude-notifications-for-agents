import AppKit
import SwiftUI

@main
struct ClaudeWebhooksApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // Menu bar only, no dock icon

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var databaseManager: DatabaseManager!
    private var httpServer: WebhookHTTPServer!
    private var mcpServer: MCPServer!
    private var sessionManager: SessionManager!
    private var tunnelManager: CloudflareTunnelManager!
    private var webhookProcessor: WebhookProcessor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize core services
        databaseManager = DatabaseManager()
        sessionManager = SessionManager()
        tunnelManager = CloudflareTunnelManager()

        webhookProcessor = WebhookProcessor(
            database: databaseManager,
            sessionManager: sessionManager
        )

        mcpServer = MCPServer(
            database: databaseManager,
            tunnelManager: tunnelManager,
            sessionManager: sessionManager
        )

        httpServer = WebhookHTTPServer(
            processor: webhookProcessor,
            mcpServer: mcpServer
        )

        // Set up menu bar
        setupMenuBar()

        // Start services
        Task {
            await startServices()
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "link.circle", accessibilityDescription: "Claude Webhooks")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 350, height: 450)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                database: databaseManager,
                tunnelManager: tunnelManager,
                sessionManager: sessionManager
            )
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func startServices() async {
        do {
            try databaseManager.initialize()
            sessionManager.startWatching()

            // Start HTTP server on background thread
            try await httpServer.start(port: 7842)

            // Wait for the server to actually be listening before starting the tunnel
            await waitForServer(port: 7842, timeout: 10)

            // Auto-start tunnel if enabled (default: true)
            if UserDefaults.standard.object(forKey: "autoStartTunnel") == nil || UserDefaults.standard.bool(forKey: "autoStartTunnel") {
                NSLog("Auto-starting Cloudflare tunnel...")
                try await tunnelManager.startTunnel()
            }
        } catch {
            NSLog("Failed to start services: \(error)")
        }
    }

    private func waitForServer(port: Int, timeout: Int) async {
        for i in 1...timeout {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if result == 0 {
                NSLog("[App] HTTP server ready on port %d after %d second(s)", port, i)
                return
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        NSLog("[App] WARNING: HTTP server not responding after %d seconds", timeout)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tunnelManager.stopTunnel()
        sessionManager.stopWatching()
    }
}
