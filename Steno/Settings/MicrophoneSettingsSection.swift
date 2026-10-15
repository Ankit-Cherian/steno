import SwiftUI
import StenoKit

struct MicrophoneSettingsSection: View {
    @Binding var preferences: AppPreferences
    @ObservedObject var model: MicrophoneTestModel
    @EnvironmentObject private var controller: DictationController
    @Environment(\.quillTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(
                section: .microphone,
                intro: "The microphone is on only while you dictate or run a test. A test is never saved and doesn’t pause media."
            )
            SettingsCard {
                SettingsRow(label: "Input", caution: missingDeviceID == nil ? nil : "Not connected. Steno uses \(systemInputName) until it’s back.",
                            isDimmed: followsSystem) {
                    Picker(selection: deviceSelection) {
                        if model.devices.isEmpty || followsSystem {
                            Label(systemInputName, systemImage: "mic").tag(String?.none)
                        }
                        ForEach(model.devices) { device in
                            Label(device.name, systemImage: "mic").tag(String?.some(device.id))
                        }
                        // The chosen microphone is unplugged: still named, so the menu never shows blank.
                        if let missingDeviceID {
                            Label(model.name(for: missingDeviceID) ?? "Chosen microphone", systemImage: "mic.slash")
                                .tag(String?.some(missingDeviceID))
                        }
                    } label: {
                        Text("Input")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(followsSystem || model.devices.isEmpty)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Test")
                        .settingsFont(.label)
                        .foregroundStyle(theme.ink)
                    Text("Speak normally. The test stops after 5 seconds. Aim for the green band.")
                        .settingsFont(.caption)
                        .foregroundStyle(theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    // The button keeps its whole name: in a narrow window the meter moves under it.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            testButton.fixedSize()
                            MicrophoneLevelBar(model: model)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            testButton.fixedSize()
                            MicrophoneLevelBar(model: model)
                        }
                    }
                    .padding(.top, 12)
                    if let failure = model.failure {
                        SettingsCautionLine(text: failure)
                            .padding(.top, 8)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsToggleRow(
                    label: "Follow the system input",
                    help: "Use whichever microphone macOS is set to, even when it changes.",
                    isOn: followSystemBinding
                )
                .disabled(model.devices.isEmpty)
            }
        }
        .onAppear { model.refreshDevices() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var testButton: some View {
        if model.isTesting {
            Button("Stop Test") { model.stop() }
                .settingsButton(.primary, small: false)
        } else {
            Button("Test Microphone") { model.start(deviceID: preferences.inputDeviceID) }
                .settingsButton(.secondary, small: false)
                .disabled(!model.isAvailable || controller.isRecording)
        }
    }

    private var followsSystem: Bool { preferences.inputDeviceID == nil }

    /// The chosen microphone when it is not connected now.
    private var missingDeviceID: String? {
        preferences.inputDeviceID.flatMap { id in model.devices.contains { $0.id == id } ? nil : id }
    }

    private var systemInputName: String {
        model.devices.first(where: \.isDefault)?.name ?? "System default"
    }

    private var deviceSelection: Binding<String?> {
        Binding(
            get: { preferences.inputDeviceID },
            set: { preferences.inputDeviceID = $0 }
        )
    }

    private var followSystemBinding: Binding<Bool> {
        Binding(
            get: { followsSystem },
            set: { follow in
                if follow {
                    preferences.inputDeviceID = nil
                } else {
                    preferences.inputDeviceID = (model.devices.first(where: \.isDefault) ?? model.devices.first)?.id
                }
            }
        )
    }
}

/// The test's level with the target band. Redraws at most 30 times a second, only while testing.
struct MicrophoneLevelBar: View {
    @ObservedObject var model: MicrophoneTestModel
    @Environment(\.quillTheme) private var theme

    private let width: CGFloat = 260

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isTesting)) { _ in
            let level = CGFloat(min(max(model.level, 0), 1))
            HStack(spacing: 14) {
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.well).frame(width: width, height: 10)
                    Capsule().fill(theme.chart).frame(width: width * level, height: 10)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.ok, lineWidth: 1.5)
                        .frame(
                            width: width * CGFloat(MicrophoneTestModel.targetBand.upperBound - MicrophoneTestModel.targetBand.lowerBound),
                            height: 18
                        )
                        .offset(x: width * CGFloat(MicrophoneTestModel.targetBand.lowerBound))
                }
                .frame(width: width, height: 18)
                .accessibilityRepresentation {
                    ProgressView(value: level) { Text("Input level") }
                        .accessibilityValue("\(Int((level * 100).rounded())) percent")
                }
                Text(model.reachedTarget ? "Good level" : "")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.ok)
                    .frame(minWidth: 80, alignment: .leading)
            }
        }
    }
}
