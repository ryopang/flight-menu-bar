import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @EnvironmentObject private var appState:     AppState
    @EnvironmentObject private var teslaService: TeslaService
    @State private var inputFlight:    String = ""
    @State private var launchAtLogin:  Bool   = false
    @State private var showTeslaSetup: Bool   = false
    @State private var showSettings:   Bool   = false
    @State private var isSendingNav:   Bool   = false
    // Settings state
    @State private var homeAddressInput: String = ""
    @State private var leadTimeMinutes:  Int    = Config.defaultLeaveByLeadMin
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if appState.isTracking {
                trackingView
            } else {
                inputView
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .onAppear {
            inputFlight      = appState.flightNumber
            launchAtLogin    = SMAppService.mainApp.status == .enabled
            homeAddressInput = UserDefaults.standard.string(forKey: Config.homeAddressKey) ?? ""
            let saved = UserDefaults.standard.integer(forKey: Config.leaveByLeadMinutesKey)
            leadTimeMinutes  = saved > 0 ? saved : Config.defaultLeaveByLeadMin
            NotificationManager.shared.requestAuthorization()
            teslaService.restoreSession()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane")
                .foregroundStyle(.blue)
                .font(.system(size: 14, weight: .semibold))
            Text("Flight Tracker")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Tracking view

    private var trackingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.flightNumber)
                        .font(.system(size: 22, weight: .bold))
                    if !appState.departureAirport.isEmpty, !appState.arrivalAirport.isEmpty {
                        Text("\(appState.departureAirport) → \(appState.arrivalAirport)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                statusBadge
            }

            if let arrival = appState.arrivalDate {
                VStack(alignment: .leading, spacing: 4) {
                    // Hero: arrival time (time only, date as small label)
                    Text(arrival.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(arrival.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                    // Countdown + status on one line
                    HStack(spacing: 6) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.countdownString(to: arrival, now: context.date))
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Self.countdownColor(to: arrival, now: context.date))
                        }
                        if appState.scheduledArrivalDate != nil {
                            if let delay = appState.delayMinutes, delay > 0 {
                                Text("· +\(delay) min")
                                    .font(.caption)
                                    .foregroundStyle(delay >= 60 ? .red : .orange)
                            } else if appState.hasLiveData {
                                Text("· On time")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Text("· Scheduled")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let minutes = appState.drivingMinutes, let arrival = appState.arrivalDate {
                        let leaveBy = arrival.addingTimeInterval(-TimeInterval(minutes * 60))
                        HStack(spacing: 6) {
                            Label("\(minutes) min drive", systemImage: "car.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Leave by \(leaveBy.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // Manual Tesla nav button
                            if teslaService.isConnected && teslaService.hasVirtualKey {
                                Button {
                                    isSendingNav = true
                                    Task {
                                        await teslaService.sendNavigation(
                                            airport: appState.arrivalAirport,
                                            terminal: appState.arrivalTerminal
                                        )
                                        isSendingNav = false
                                    }
                                } label: {
                                    if isSendingNav {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "bolt.car.fill")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isSendingNav)
                                .help("Send navigation to Tesla now")
                            }
                        }
                    }
                    if isNYNJArrival, let info = terminalText {
                        Text(info)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let dep = appState.departureCoordinate, let arr = appState.arrivalCoordinate {
                FlightMapView(
                    departure: dep,
                    arrival: arr,
                    position: appState.currentPosition
                )
            }

            HStack {
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("Stop") {
                    appState.stopTracking()
                    inputFlight = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(14)
    }

    // MARK: - Input view

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("e.g. AA123, UA456", text: $inputFlight)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { beginTracking() }
                    .disabled(appState.isLoading)
                    .textCase(.uppercase)

                Button {
                    beginTracking()
                } label: {
                    if appState.isLoading {
                        ProgressView().controlSize(.small).frame(width: 40)
                    } else {
                        Text("Track").frame(width: 40)
                    }
                }
                .disabled(inputFlight.trimmingCharacters(in: .whitespaces).isEmpty || appState.isLoading)
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }
        }
        .padding(14)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            // Tesla row / setup wizard
            if showTeslaSetup {
                teslaSetupView
            } else {
                teslaStatusRow
            }

            // Settings panel
            if showSettings {
                settingsView
            }

            Divider()
            HStack {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .toggleStyle(.checkbox)
                Spacer()
                // Settings gear toggle
                Button {
                    showSettings.toggle()
                    if showSettings { showTeslaSetup = false }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundStyle(showSettings ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Settings panel

    @ViewBuilder
    private var settingsView: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.bottom, 10)

            // Home address
            VStack(alignment: .leading, spacing: 5) {
                Text("Home Address")
                    .font(.caption2.uppercaseSmallCaps())
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    TextField(Config.homeAddress, text: $homeAddressInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Save") { saveHomeAddress() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(homeAddressInput.trimmingCharacters(in: .whitespaces).isEmpty
                                  || homeAddressInput == Config.homeAddress)
                }
            }

            Divider()
                .padding(.vertical, 10)

            // Leave-by lead time
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Leave-by Alert")
                        .font(.caption2.uppercaseSmallCaps())
                        .foregroundStyle(.tertiary)
                    Text("\(leadTimeMinutes) min before departure")
                        .font(.caption)
                }
                Spacer()
                Stepper("", value: $leadTimeMinutes, in: 0...30, step: 5)
                    .labelsHidden()
                    .onChange(of: leadTimeMinutes) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: Config.leaveByLeadMinutesKey)
                        if let arrival = appState.arrivalDate, let drive = appState.drivingMinutes {
                            NotificationManager.shared.scheduleLeaveByNotification(
                                airport: appState.arrivalAirport,
                                terminal: appState.arrivalTerminal,
                                arrivalDate: arrival,
                                drivingMinutes: drive
                            )
                        }
                    }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Tesla status row (collapsed)

    @ViewBuilder
    private var teslaStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: teslaIcon)
                .font(.caption)
                .foregroundStyle(teslaIconColor)

            if teslaService.isConnecting {
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            } else if teslaService.isConnected && teslaService.hasVirtualKey {
                Text("Tesla ready").font(.caption).foregroundStyle(.secondary)
                if let pct = teslaService.batteryLevel {
                    Text("\(pct)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(pct < 20 ? .red : pct < 40 ? .orange : .secondary)
                }
                Spacer()
                Button("Disconnect") { teslaService.disconnect() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.red.opacity(0.8))
            } else if teslaService.isConnected && !teslaService.hasVirtualKey {
                Text("Tesla — virtual key needed").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Setup") { showTeslaSetup = true; showSettings = false }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
            } else {
                Text(teslaService.lastError ?? "Tesla not connected")
                    .font(.caption)
                    .foregroundStyle(teslaService.lastError != nil ? .red.opacity(0.8) : .secondary)
                Spacer()
                Button("Setup") { showTeslaSetup = true; showSettings = false }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
            }
        }
    }

    private var teslaIcon: String {
        if teslaService.isConnected && teslaService.hasVirtualKey { return "bolt.car.fill" }
        return "bolt.car"
    }
    private var teslaIconColor: Color {
        if teslaService.isConnected && teslaService.hasVirtualKey { return .green }
        if teslaService.isConnected { return .orange }
        return .secondary
    }

    // MARK: - Tesla setup wizard (expanded)

    @ViewBuilder
    private var teslaSetupView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tesla Setup").font(.caption.bold())
                Spacer()
                Button("✕") { showTeslaSetup = false }.buttonStyle(.plain).font(.caption)
            }

            if !teslaService.isConnected {
                setupStep(number: "1", title: "Sign in with Tesla") {
                    Button("Open Tesla Login") { teslaService.startAuth() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Text("✓ Tesla account connected").font(.caption).foregroundStyle(.green)
            }

            setupStep(number: "2", title: "Host your public key on Vercel") {
                if let pem = teslaService.publicKeyPEM {
                    Button("Regenerate Key") { _ = teslaService.generateVirtualKey() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Text("Save to your Vercel repo at:")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("public/.well-known/appspecific/com.tesla.3p.public-key.pem")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(alignment: .top, spacing: 4) {
                        Text(pem)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pem, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy PEM to clipboard")
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Button("Generate Key") { _ = teslaService.generateVirtualKey() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }

            setupStep(number: "3", title: "Add key to your Tesla") {
                Button {
                    Task { await teslaService.registerAndOpenKeyURL() }
                } label: {
                    if teslaService.isRegisteringPartner {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Registering…")
                        }
                    } else {
                        Text("Open tesla.com/_ak link")
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(teslaService.isRegisteringPartner)
                Text("Tap 'Add' in the Tesla app when prompted.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let err = teslaService.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                if !teslaService.hasVirtualKey {
                    Button("I've added the key ✓") {
                        teslaService.markVirtualKeyAdded()
                        showTeslaSetup = false
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Text("✓ Virtual key added").font(.caption2).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func setupStep<Content: View>(number: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(number)
                    .font(.caption2.bold())
                    .frame(width: 14, height: 14)
                    .background(Color.accentColor.opacity(0.2))
                    .clipShape(Circle())
                Text(title).font(.caption.bold())
            }
            content()
                .padding(.leading, 18)
        }
    }

    // MARK: - Helpers

    private func saveHomeAddress() {
        let trimmed = homeAddressInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Config.homeAddressKey)
        DrivingService.clearCache()
        // Re-fetch driving time with the new address if currently tracking
        if appState.isTracking {
            Task { await appState.refreshDriving() }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                if newValue { try? SMAppService.mainApp.register() }
                else        { try? SMAppService.mainApp.unregister() }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private static let nynjAirports: Set<String> = ["JFK", "LGA", "EWR", "HPN"]
    private var isNYNJArrival: Bool { Self.nynjAirports.contains(appState.arrivalIATACode.uppercased()) }
    private var terminalText: String? { appState.arrivalTerminal.map { "Terminal \($0)" } }

    private var statusBadge: some View {
        let (color, label) = statusStyle
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var statusStyle: (Color, String) {
        switch appState.flightStatus.lowercased() {
        case "enroute", "en route":  return (.green,  "En Route")
        case "departed":             return (.blue,   "Departed")
        case "expected", "scheduled":return (.blue,   "Scheduled")
        case "boarding":             return (.orange, "Boarding")
        case "gateclosed":           return (.orange, "Gate Closed")
        case "delayed":              return (.red,    "Delayed")
        case "approaching":          return (.green,  "Approaching")
        case "landed", "arrived":    return (.gray,   "Arrived")
        case "canceled", "cancelled":return (.red,    "Cancelled")
        case "diverted":             return (.red,    "Diverted")
        default:
            return (.secondary, appState.flightStatus.isEmpty ? "Unknown" : appState.flightStatus)
        }
    }

    private static func countdownString(to arrival: Date, now: Date) -> String {
        let remaining = arrival.timeIntervalSince(now)
        guard remaining > 0 else { return "Arrived" }
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        return "\(m)m \(s)s"
    }

    private static func countdownColor(to arrival: Date, now: Date) -> Color {
        let r = arrival.timeIntervalSince(now)
        if r <= 0    { return .secondary }
        if r < 3_600 { return .orange }
        return .primary
    }

    private func beginTracking() {
        let n = inputFlight.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task { await appState.startTracking(with: n) }
    }
}
