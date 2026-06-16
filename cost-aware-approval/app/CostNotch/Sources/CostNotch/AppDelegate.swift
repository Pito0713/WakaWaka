import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var pollingTimer: Timer?

    // Published-like state: updated on main thread, drives popover refresh
    private var pendingData: PendingData?
    private var usageOutput: UsageOutput?
    private var isLoadingUsage = false
    private var lastPendingTimestamp: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        setupPopover()
        startPolling()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(hasPending: false)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        refreshPopoverContent()
    }

    private func setIcon(hasPending: Bool) {
        guard let button = statusItem.button else { return }
        let name = hasPending ? "dollarsign.circle.fill" : "dollarsign.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "CostNotch")
        // Tint the icon orange when there's a pending request
        button.contentTintColor = hasPending ? .systemOrange : nil
    }

    // MARK: - Polling

    private func startPolling() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    private func poll() {
        let pendingURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".costnotch/state/pending.json")

        guard FileManager.default.fileExists(atPath: pendingURL.path),
              let data = try? Data(contentsOf: pendingURL),
              let pending = try? JSONDecoder().decode(PendingData.self, from: data) else {
            // File gone → clear state
            if pendingData != nil {
                pendingData = nil
                usageOutput = nil
                isLoadingUsage = false
                lastPendingTimestamp = nil
                setIcon(hasPending: false)
                popover.performClose(nil)
                refreshPopoverContent()
            }
            return
        }

        // Avoid re-fetching for the same pending request
        if lastPendingTimestamp == pending.timestamp { return }
        lastPendingTimestamp = pending.timestamp
        pendingData = pending
        usageOutput = nil
        isLoadingUsage = true
        setIcon(hasPending: true)
        refreshPopoverContent()
        showPopover()

        // Fetch usage off main thread
        let capturedTimestamp = pending.timestamp
        if let transcriptPath = pending.transcript_path {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = ParserRunner.run(transcriptPath: transcriptPath)
                DispatchQueue.main.async {
                    guard let self, self.lastPendingTimestamp == capturedTimestamp else { return }
                    self.usageOutput = result
                    self.isLoadingUsage = false
                    self.refreshPopoverContent()
                }
            }
        } else {
            isLoadingUsage = false
            refreshPopoverContent()
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        refreshPopoverContent()
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshPopoverContent() {
        let view = ContentView(
            pending: pendingData,
            usage: usageOutput,
            isLoading: isLoadingUsage,
            onAllow:       { [weak self] in self?.allow() },
            onAlwaysAllow: { [weak self] in self?.alwaysAllow() },
            onDeny:        { [weak self] in self?.deny() }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 340, height: pendingData == nil ? 100 : 260)
    }

    // MARK: - Decision

    func allow() {
        writeDecision(#"{"decision":"allow"}"#)
        clearPending()
    }

    func alwaysAllow() {
        // Hook receives "always" → saves prefix to ~/.costnotch/allowlist.json → exits 0
        writeDecision(#"{"decision":"always"}"#)
        clearPending()
    }

    func deny() {
        writeDecision(#"{"decision":"deny","reason":"User denied"}"#)
        clearPending()
    }

    private func writeDecision(_ json: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".costnotch/state/decision.json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Writing decision is critical — log so user knows hook will timeout
            fputs("[CostNotch] ERROR: failed to write decision.json: \(error)\n", stderr)
        }
    }

    private func clearPending() {
        pendingData = nil
        usageOutput = nil
        isLoadingUsage = false
        lastPendingTimestamp = nil
        setIcon(hasPending: false)
        popover.performClose(nil)
        refreshPopoverContent()
    }
}
