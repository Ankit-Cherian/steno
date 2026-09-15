#ifndef STENO_RUNTIME_SOURCE
#define STENO_RUNTIME_SOURCE "../runtime-helper/steno_whisper_runtime.cpp"
#endif
#define main steno_runtime_entrypoint
#include STENO_RUNTIME_SOURCE
#undef main

#include <iostream>
#include <utility>

struct whisper_vad_segments {
    int count;
};

namespace {
enum class ProbeMode { Speech, Silence, PartialError, StaleError, WorkerError, Warning, Exception };
ProbeMode probe_mode = ProbeMode::Speech;
int freed_contexts = 0;

void require(bool condition, const char * message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}
}

// Substitute only the VAD boundary. All mask acceptance, callback handling,
// evidence classification and context invalidation use production helper code.
extern "C" whisper_vad_segments * whisper_vad_segments_from_samples(
    whisper_vad_context *, whisper_vad_params, const float *, int
) {
    if (probe_mode == ProbeMode::Exception) {
        throw std::runtime_error("VAD allocation failure");
    }
    if (probe_mode == ProbeMode::PartialError || probe_mode == ProbeMode::StaleError) {
        observe_backend_log(GGML_LOG_LEVEL_ERROR, "compute error", nullptr);
    } else if (probe_mode == ProbeMode::WorkerError) {
        std::thread worker([] {
            observe_backend_log(GGML_LOG_LEVEL_ERROR, "worker error", nullptr);
        });
        worker.join();
    } else if (probe_mode == ProbeMode::Warning) {
        observe_backend_log(GGML_LOG_LEVEL_WARN, "diagnostic warning", nullptr);
    }
    return new whisper_vad_segments{
        probe_mode == ProbeMode::Silence || probe_mode == ProbeMode::StaleError ? 0 : 1
    };
}

extern "C" int whisper_vad_segments_n_segments(whisper_vad_segments * segments) {
    return segments->count;
}
extern "C" float whisper_vad_segments_get_segment_t0(whisper_vad_segments *, int) { return 0; }
extern "C" float whisper_vad_segments_get_segment_t1(whisper_vad_segments *, int) { return 100; }
extern "C" void whisper_vad_free_segments(whisper_vad_segments * segments) { delete segments; }
extern "C" void whisper_vad_free(whisper_vad_context *) { ++freed_contexts; }

int main() {
    const auto default_context_parameters = whisper_vad_default_context_params();
    const std::pair<unsigned, int> thread_cases[] = {
        {0, 1}, {1, 1}, {2, 2}, {3, 3}, {4, 4}, {8, 4},
        {std::numeric_limits<unsigned>::max(), 4},
    };
    for (const auto & [hardware_threads, expected_threads] : thread_cases) {
        const auto bounded = bounded_vad_context_parameters(hardware_threads);
        require(bounded.n_threads == expected_threads,
            "VAD workers must respect the hardware count with a nonzero fallback");
        require(bounded.use_gpu == default_context_parameters.use_gpu
            && bounded.gpu_device == default_context_parameters.gpu_device,
            "bounding VAD workers must preserve backend selection");
    }

    int context_marker = 0;
    auto * context = reinterpret_cast<whisper_vad_context *>(&context_marker);
    const std::vector<float> input(16000, 0.125f);
    const auto parameters = whisper_vad_default_params();
    PreparedAudio prepared;

    observe_backend_log(GGML_LOG_LEVEL_ERROR, "previous request error", nullptr);
    require(prepare_vad_audio(context, parameters, input, prepared), "prior errors must not poison a healthy call");
    require(prepared.speech_detected && prepared.samples.size() == 15999, "healthy speech remains intact");
    require(std::all_of(prepared.samples.begin(), prepared.samples.end(), [](float sample) {
        return sample == 0.125f;
    }), "healthy PCM values remain unchanged");

    probe_mode = ProbeMode::PartialError;
    require(!prepare_vad_audio(context, parameters, input, prepared), "a partial mask after ERROR must be rejected");
    require(prepared.samples.empty() && prepared.time_mapping.empty(), "failed preparation must clear prior output");

    probe_mode = ProbeMode::StaleError;
    require(!prepare_vad_audio(context, parameters, input, prepared), "an empty mask after ERROR is not confirmed silence");
    probe_mode = ProbeMode::WorkerError;
    require(!prepare_vad_audio(context, parameters, input, prepared), "backend worker ERROR must invalidate the mask");
    probe_mode = ProbeMode::Warning;
    require(prepare_vad_audio(context, parameters, input, prepared), "a warning is not a failed inference");
    probe_mode = ProbeMode::Silence;
    require(prepare_vad_audio(context, parameters, input, prepared), "healthy silence should succeed");
    require(!prepared.speech_detected && prepared.samples.empty(), "healthy silence remains gated");

    RequestConfiguration request;
    request.vad_model_path = "fixture-vad";
    std::string loaded_path = request.vad_model_path;
    std::atomic<bool> aborted{false};
    PreviewSpeechEvidence evidence = PreviewSpeechEvidence::Speech;
    probe_mode = ProbeMode::PartialError;
    require(detect_preview_speech(context, loaded_path, request, std::vector<int16_t>(16000, 4096), aborted, evidence),
        "failed optional evidence must preserve the live path");
    require(evidence == PreviewSpeechEvidence::Unknown, "failed VAD must produce Unknown evidence");
    require(context == nullptr && loaded_path.empty() && freed_contexts == 1,
        "failed preview must discard its contaminated VAD context");

    context = reinterpret_cast<whisper_vad_context *>(&context_marker);
    loaded_path = request.vad_model_path;
    evidence = PreviewSpeechEvidence::Speech;
    probe_mode = ProbeMode::Exception;
    require(detect_preview_speech(context, loaded_path, request, std::vector<int16_t>(16000, 4096), aborted, evidence),
        "optional VAD exceptions must preserve the live path");
    require(evidence == PreviewSpeechEvidence::Unknown, "VAD exceptions must produce Unknown evidence");
    require(context == nullptr && loaded_path.empty() && freed_contexts == 2,
        "preview exceptions must discard the VAD context");

    std::cout << "PASS: VAD integrity, worker errors, healthy speech/silence, and Unknown preview recovery\n";
}
