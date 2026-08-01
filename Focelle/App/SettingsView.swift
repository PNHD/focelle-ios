import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var beta: BetaAccess
    @EnvironmentObject private var account: Account
    @ObservedObject var camera: CameraSession

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        beta.snapshot.enabled ? "beta.freeMessage" : "beta.endedMessage",
                        systemImage: "sparkles"
                    )
                    .foregroundStyle(.orange)
                }

                Section {
                    Toggle("settings.onDeviceOnly", isOn: $settings.onDeviceOnly)
                    Toggle("guidance.toggle", isOn: $settings.guidanceEnabled)
                    Toggle("voice.toggle", isOn: $settings.voiceGuidance)
                    Toggle("autoCapture.toggle", isOn: $settings.autoCapture)
                } header: {
                    Text("settings.ai")
                } footer: {
                    Text("settings.aiFooter")
                }

                Section("settings.camera") {
                    Toggle("settings.saveOriginal", isOn: $settings.saveOriginal)
                    Toggle("settings.saveLocation", isOn: $settings.saveLocation)
                    if camera.standardModeLabel != "—" {
                        Picker("settings.resolution", selection: $settings.requestedResolution) {
                            Text("\(camera.standardModeLabel) MP").tag(CameraResolution.standard)
                            if camera.supportsBalancedResolution {
                                Text("\(camera.balancedModeLabel) MP").tag(CameraResolution.balanced)
                            }
                            if camera.supportsMaximumResolution {
                                Text("\(camera.maximumModeLabel) MP").tag(CameraResolution.maximum)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("settings.privacy") {
                    Toggle("settings.analytics", isOn: $settings.analyticsEnabled)
                    NavigationLink("settings.privacyDetails") {
                        PrivacyView()
                    }
                }

                if account.isSignedIn {
                    Section("account.title") {
                        NavigationLink("account.manage") {
                            AccountView().environmentObject(account)
                        }
                    }
                }
            }
            .navigationTitle("settings.title")
            .onChange(of: settings.saveLocation) { _, enabled in
                location.setEnabled(enabled)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }
}

private struct PrivacyView: View {
    var body: some View {
        List {
            privacyRow(
                "lock.iphone",
                title: "privacy.onDeviceTitle",
                detail: "privacy.onDeviceDetail"
            )
            privacyRow(
                "cloud",
                title: "privacy.cloudTitle",
                detail: "privacy.cloudDetail"
            )
            privacyRow(
                "photo",
                title: "privacy.photoTitle",
                detail: "privacy.photoDetail"
            )
            privacyRow(
                "chart.bar",
                title: "privacy.analyticsTitle",
                detail: "privacy.analyticsDetail"
            )
        }
        .navigationTitle("settings.privacy")
    }

    private func privacyRow(
        _ icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
    }
}
