import SwiftUI

struct MicButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let handsFreeOn: Bool
    let onTap: () -> Void

    @State private var glowAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Glow ring (visible only when recording)
                if isRecording {
                    Circle()
                        .stroke(StenoDesign.accent, lineWidth: StenoDesign.borderHeavy)
                        .frame(width: StenoDesign.micButtonGlowSize, height: StenoDesign.micButtonGlowSize)
                        .opacity(reduceMotion ? StenoDesign.opacityDisabled : (glowAnimating ? StenoDesign.opacityGlowMax : StenoDesign.opacityMuted))
                        .scaleEffect(reduceMotion ? 1.0 : (glowAnimating ? StenoDesign.micButtonGlowScale : 1.0))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: StenoDesign.animationGlow).repeatForever(autoreverses: true),
                            value: glowAnimating
                        )
                }

                // Main circle
                Circle()
                    .fill(isRecording ? StenoDesign.accent : StenoDesign.surface)
                    .frame(width: StenoDesign.micButtonSize, height: StenoDesign.micButtonSize)
                    .shadowStyle(isRecording ? .recording : .idle)
                    .overlay(
                        Circle()
                            .stroke(
                                isRecording ? Color.clear : StenoDesign.border,
                                lineWidth: StenoDesign.borderNormal
                            )
                    )
                    .animation(
                        reduceMotion ? nil : .spring(response: StenoDesign.animationNormal, dampingFraction: 0.8),
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
                            .font(.system(size: StenoDesign.iconXL, weight: .medium))
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
        .buttonStyle(.plain)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(micAccessibilityHint)
        .accessibilityValue(micAccessibilityValue)
        .onChange(of: isRecording) { recording in
            glowAnimating = recording
        }
        .onAppear {
            if isRecording {
                glowAnimating = true
            }
        }
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
