import SwiftUI

struct MicButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let handsFreeOn: Bool
    let onTap: () -> Void

    @State private var innerGlowActive = false
    @State private var outerGlowActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                micButton
                    .onChange(of: isRecording) { _, recording in
                        handleRecordingChange(recording)
                    }
            } else {
                micButton
                    .onChange(of: isRecording) { recording in
                        handleRecordingChange(recording)
                    }
            }
        }
        .onAppear {
            if isRecording {
                innerGlowActive = true
                outerGlowActive = true
            }
        }
    }

    private func handleRecordingChange(_ recording: Bool) {
        if recording {
            innerGlowActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                outerGlowActive = true
            }
        } else {
            innerGlowActive = false
            outerGlowActive = false
        }
    }

    private var micButton: some View {
        Button {
            onTap()
        } label: {
            ZStack {
                // Outer glow ring (visible only when recording)
                if isRecording {
                    Circle()
                        .stroke(
                            StenoDesign.accent,
                            lineWidth: StenoDesign.borderThick
                        )
                        .frame(
                            width: StenoDesign.micButtonOuterRingSize,
                            height: StenoDesign.micButtonOuterRingSize
                        )
                        .opacity(
                            reduceMotion
                                ? StenoDesign.opacityBorder
                                : (outerGlowActive ? 0.25 : 0.0)
                        )
                        .scaleEffect(
                            reduceMotion
                                ? 1.0
                                : (outerGlowActive ? 1.15 : 1.0)
                        )
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                            value: outerGlowActive
                        )
                }

                // Inner glow ring (visible only when recording)
                if isRecording {
                    Circle()
                        .stroke(
                            StenoDesign.accent,
                            lineWidth: StenoDesign.borderThick
                        )
                        .frame(
                            width: StenoDesign.micButtonInnerRingSize,
                            height: StenoDesign.micButtonInnerRingSize
                        )
                        .opacity(
                            reduceMotion
                                ? StenoDesign.opacityBorder
                                : (innerGlowActive ? 0.4 : 0.0)
                        )
                        .scaleEffect(
                            reduceMotion
                                ? 1.0
                                : (innerGlowActive ? 1.15 : 1.0)
                        )
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                            value: innerGlowActive
                        )
                }

                // Main circle
                Circle()
                    .fill(isRecording ? StenoDesign.accent : StenoDesign.surface)
                    .frame(width: StenoDesign.micButtonSize, height: StenoDesign.micButtonSize)
                    .shadow(
                        color: isRecording ? StenoDesign.accent.opacity(0.25) : .black.opacity(0.14),
                        radius: isRecording ? 16 : 6,
                        x: 0,
                        y: 2
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                isRecording ? Color.clear : StenoDesign.border,
                                lineWidth: StenoDesign.borderNormal
                            )
                    )
                    .animation(
                        reduceMotion ? nil : Animation.spring(response: StenoDesign.animationNormal, dampingFraction: 0.8),
                        value: isRecording
                    )

                // Icon / progress overlay
                ZStack {
                    if isTranscribing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.regular)
                            .tint(.white)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: StenoDesign.micButtonIconSize, weight: .medium))
                            .foregroundStyle(isRecording ? .white : StenoDesign.accent)
                            .transition(reduceMotion ? .opacity : .scale(scale: 1.1).combined(with: .opacity))
                    }
                }
                .animation(
                    reduceMotion ? nil : .spring(response: StenoDesign.animationNormal, dampingFraction: 0.8),
                    value: isTranscribing
                )
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(micAccessibilityHint)
        .accessibilityValue(micAccessibilityValue)
    }

    private var micAccessibilityLabel: String {
        if isRecording { return "Microphone, recording" }
        if isTranscribing { return "Microphone, transcribing" }
        return "Microphone"
    }

    private var micAccessibilityHint: String {
        if isTranscribing { return "Transcription in progress" }
        if isRecording { return "Tap to stop recording" }
        return "Tap to start hands-free recording"
    }

    private var micAccessibilityValue: String {
        if isRecording { return "Recording" }
        if isTranscribing { return "Transcribing" }
        if handsFreeOn { return "Hands-free active" }
        return "Idle"
    }
}
