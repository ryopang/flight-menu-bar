import SwiftUI
import AppKit

// NSApplicationDelegate handles the custom URL scheme OAuth callback.
// SwiftUI's .onOpenURL is not supported on MenuBarExtra scenes.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for the 'GURL' Apple Event that macOS sends for custom URL schemes
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:replyEvent:)),
            forEventClass: 0x4755524C, // kInternetEventClass 'GURL'
            andEventID:    0x4755524C  // kAEGetURL            'GURL'
        )
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "flightmenubar" else { return }
        Task { await TeslaService.shared.handleCallback(url: url) }
    }
}

@main
struct FlightMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState     = AppState()
    @StateObject private var teslaService = TeslaService.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(teslaService)
        } label: {
            Text(appState.menuBarLabel)
                .monospacedDigit()
                .foregroundStyle(labelColor)
        }
        .menuBarExtraStyle(.window)
    }

    private var labelColor: Color {
        guard appState.isTracking else { return .primary }
        guard let delay = appState.delayMinutes, delay > 0 else { return .green }
        return delay >= 60 ? .red : .orange
    }
}
