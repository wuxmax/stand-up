import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @State private var sitMinutes: Double = 30
    @State private var standMinutes: Double = 5
    @State private var sitHeightMm: Double = 100
    @State private var standHeightMm: Double = 600
    @State private var baseHeightMm: Double = 0
    @State private var deskAddress: String = ""
    @State private var warningSeconds: Double = 30

    var body: some View {
        TabView {
            timerTab
                .tabItem { Label("Timer", systemImage: "timer") }
            deskTab
                .tabItem { Label("Desk", systemImage: "macwindow") }
        }
        .frame(width: 460, height: 420)
        .onAppear { seedFromState() }
    }

    private var timerTab: some View {
        Form {
            Section("Sitting interval") {
                Slider(value: sitMinutesBinding, in: 1...60) {
                    Text("Minutes")
                } minimumValueLabel: {
                    Text("1")
                } maximumValueLabel: {
                    Text("60")
                }
                .padding(.vertical, 4)
                HStack {
                    Spacer()
                    Text("\(Int(sitMinutes)) min")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Section("Standing interval") {
                Slider(value: standMinutesBinding, in: 1...60) {
                    Text("Minutes")
                } minimumValueLabel: {
                    Text("1")
                } maximumValueLabel: {
                    Text("60")
                }
                .padding(.vertical, 4)
                HStack {
                    Spacer()
                    Text("\(Int(standMinutes)) min")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: sitMinutes) { _, _ in persistTimerSettings() }
        .onChange(of: standMinutes) { _, _ in persistTimerSettings() }
    }

    private var deskTab: some View {
        Form {
            Section("Desk control") {
                Toggle("Enable desk control", isOn: deskEnabledBinding)
                Toggle("Auto-move desk on interval end", isOn: autoControlBinding)
                    .disabled(!appState.isDeskControlEnabled)
                if appState.isDeskControlEnabled && appState.autoControlDesk {
                    Slider(value: $warningSeconds, in: 5...180, step: 5) {
                        Text("Move warning")
                    }
                    HStack {
                        Text("\(Int(warningSeconds)) s before the desk moves")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                    }
                    .onChange(of: warningSeconds) { _, _ in persistTimerSettings() }
                }
            }

            Section("LINAK connection") {
                TextField("Desk UUID (optional — leave blank to auto-scan)", text: $deskAddress)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: deskAddress) { _, _ in persistDeskSettings() }
                LabeledContent("Base height (mm)") {
                    TextField("auto", value: $baseHeightMm, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                .onChange(of: baseHeightMm) { _, _ in persistDeskSettings() }
            }

            Section("Favourite heights (mm above floor)") {
                LabeledContent("Sit") {
                    TextField("0–1300", value: $sitHeightMm, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                .onChange(of: sitHeightMm) { _, _ in persistDeskSettings() }
                LabeledContent("Stand") {
                    TextField("0–1300", value: $standHeightMm, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                .onChange(of: standHeightMm) { _, _ in persistDeskSettings() }
            }

            if appState.isDeskControlEnabled {
                Section("Desk log") {
                    ScrollView {
                        Text(appState.deskLog.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 80)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var deskEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.isDeskControlEnabled },
            set: { v in
                DispatchQueue.main.async { appState.setDeskControlEnabled(v) }
            }
        )
    }

    private var autoControlBinding: Binding<Bool> {
        Binding(
            get: { appState.autoControlDesk },
            set: { v in
                DispatchQueue.main.async { appState.autoControlDesk = v }
            }
        )
    }

    private var sitMinutesBinding: Binding<Double> {
        Binding(
            get: { sitMinutes },
            set: { v in sitMinutes = v.rounded() }
        )
    }

    private var standMinutesBinding: Binding<Double> {
        Binding(
            get: { standMinutes },
            set: { v in standMinutes = v.rounded() }
        )
    }

    private func persistTimerSettings() {
        var s = appState.timerSettings
        s.sitInterval = round(sitMinutes) * 60
        s.standInterval = round(standMinutes) * 60
        s.warningLeadTime = warningSeconds
        DispatchQueue.main.async { appState.updateTimerSettings(s) }
    }

    private func persistDeskSettings() {
        var s = appState.deskSettings
        s.sitHeightMm = DeskSettings.clamp(Int(sitHeightMm))
        s.standHeightMm = DeskSettings.clamp(Int(standHeightMm))
        s.baseHeightMm = baseHeightMm > 0 ? Int(baseHeightMm) : nil
        s.deskAddress = deskAddress
        DispatchQueue.main.async { appState.updateDeskSettings(s) }
    }

    private func seedFromState() {
        sitMinutes = appState.timerSettings.sitInterval / 60
        standMinutes = appState.timerSettings.standInterval / 60
        warningSeconds = appState.timerSettings.warningLeadTime
        sitHeightMm = Double(appState.deskSettings.sitHeightMm)
        standHeightMm = Double(appState.deskSettings.standHeightMm)
        baseHeightMm = Double(appState.deskSettings.baseHeightMm ?? 0)
        deskAddress = appState.deskSettings.deskAddress
    }
}