#include "whisper.h"

#include <algorithm>
#include <atomic>
#include <cfloat>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>
#include <sys/event.h>

namespace {

constexpr uint32_t kMagic = 0x53545752;
constexpr uint16_t kVersion = 1;
constexpr uint32_t kMaximumPayloadBytes = 64U * 1024U * 1024U;
constexpr uint32_t kMaximumStringBytes = 1024U * 1024U;

enum class Operation : uint16_t {
    Load = 1,
    Ready = 2,
    Transcribe = 3,
    Result = 4,
    Error = 5,
    Shutdown = 6,
    Stopped = 7,
    Cancelled = 8,
};

enum class ErrorCategory : uint32_t {
    Protocol = 1,
    ModelLoad = 2,
    Audio = 3,
    Inference = 4,
    Internal = 5,
};

struct Frame {
    Operation operation = Operation::Error;
    uint8_t request_id[16] = {};
    uint64_t generation = 0;
    std::vector<uint8_t> payload;
};

struct RequestConfiguration {
    int threads = 1;
    int beam_size = 5;
    int best_of = 5;
    bool suppress_non_speech_tokens = true;
    std::string audio_path;
    std::string language;
    std::string prompt;
    std::string suppress_regex;
    std::string vad_model_path;
};

struct TimeMapping {
    int64_t processed_time = 0;
    int64_t original_time = 0;
};

struct PreparedAudio {
    std::vector<float> samples;
    std::vector<TimeMapping> time_mapping;
    bool speech_detected = true;
};

class PayloadReader {
public:
    explicit PayloadReader(const std::vector<uint8_t> & data) : data_(data) {}

    bool read_u32(uint32_t & value) {
        if (offset_ + 4 > data_.size()) {
            return false;
        }
        value = (static_cast<uint32_t>(data_[offset_]) << 24)
              | (static_cast<uint32_t>(data_[offset_ + 1]) << 16)
              | (static_cast<uint32_t>(data_[offset_ + 2]) << 8)
              | static_cast<uint32_t>(data_[offset_ + 3]);
        offset_ += 4;
        return true;
    }

    bool read_string(std::string & value, bool optional = false) {
        uint32_t size = 0;
        if (!read_u32(size)) {
            return false;
        }
        if (optional && size == std::numeric_limits<uint32_t>::max()) {
            value.clear();
            return true;
        }
        if (size > kMaximumStringBytes || offset_ + size > data_.size()) {
            return false;
        }
        value.assign(reinterpret_cast<const char *>(data_.data() + offset_), size);
        offset_ += size;
        return true;
    }

    bool exhausted() const {
        return offset_ == data_.size();
    }

private:
    const std::vector<uint8_t> & data_;
    size_t offset_ = 0;
};

bool read_exact(int fd, void * destination, size_t count) {
    auto * bytes = static_cast<uint8_t *>(destination);
    size_t offset = 0;
    while (offset < count) {
        const ssize_t result = read(fd, bytes + offset, count - offset);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0) {
            return false;
        }
        offset += static_cast<size_t>(result);
    }
    return true;
}

bool write_exact(int fd, const void * source, size_t count) {
    const auto * bytes = static_cast<const uint8_t *>(source);
    size_t offset = 0;
    while (offset < count) {
        const ssize_t result = write(fd, bytes + offset, count - offset);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0) {
            return false;
        }
        offset += static_cast<size_t>(result);
    }
    return true;
}

uint16_t read_u16(const uint8_t * bytes) {
    return static_cast<uint16_t>((static_cast<uint16_t>(bytes[0]) << 8) | bytes[1]);
}

uint32_t read_u32(const uint8_t * bytes) {
    return (static_cast<uint32_t>(bytes[0]) << 24)
         | (static_cast<uint32_t>(bytes[1]) << 16)
         | (static_cast<uint32_t>(bytes[2]) << 8)
         | static_cast<uint32_t>(bytes[3]);
}

uint64_t read_u64(const uint8_t * bytes) {
    uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value = (value << 8) | bytes[index];
    }
    return value;
}

void write_u16(uint8_t * bytes, uint16_t value) {
    bytes[0] = static_cast<uint8_t>((value >> 8) & 0xff);
    bytes[1] = static_cast<uint8_t>(value & 0xff);
}

void write_u32(uint8_t * bytes, uint32_t value) {
    bytes[0] = static_cast<uint8_t>((value >> 24) & 0xff);
    bytes[1] = static_cast<uint8_t>((value >> 16) & 0xff);
    bytes[2] = static_cast<uint8_t>((value >> 8) & 0xff);
    bytes[3] = static_cast<uint8_t>(value & 0xff);
}

void write_u64(uint8_t * bytes, uint64_t value) {
    for (int index = 7; index >= 0; --index) {
        bytes[index] = static_cast<uint8_t>(value & 0xff);
        value >>= 8;
    }
}

bool read_frame(Frame & frame) {
    uint8_t header[36] = {};
    if (!read_exact(STDIN_FILENO, header, sizeof(header))) {
        return false;
    }
    if (read_u32(header) != kMagic || read_u16(header + 4) != kVersion) {
        return false;
    }
    const auto raw_operation = read_u16(header + 6);
    if (raw_operation < static_cast<uint16_t>(Operation::Load)
        || raw_operation > static_cast<uint16_t>(Operation::Cancelled)) {
        return false;
    }
    frame.operation = static_cast<Operation>(raw_operation);
    std::memcpy(frame.request_id, header + 8, sizeof(frame.request_id));
    frame.generation = read_u64(header + 24);
    const uint32_t payload_size = read_u32(header + 32);
    if (payload_size > kMaximumPayloadBytes) {
        return false;
    }
    frame.payload.resize(payload_size);
    return payload_size == 0 || read_exact(STDIN_FILENO, frame.payload.data(), payload_size);
}

bool write_frame(const Frame & frame) {
    if (frame.payload.size() > kMaximumPayloadBytes) {
        return false;
    }
    uint8_t header[36] = {};
    write_u32(header, kMagic);
    write_u16(header + 4, kVersion);
    write_u16(header + 6, static_cast<uint16_t>(frame.operation));
    std::memcpy(header + 8, frame.request_id, sizeof(frame.request_id));
    write_u64(header + 24, frame.generation);
    write_u32(header + 32, static_cast<uint32_t>(frame.payload.size()));
    return write_exact(STDOUT_FILENO, header, sizeof(header))
        && (frame.payload.empty() || write_exact(STDOUT_FILENO, frame.payload.data(), frame.payload.size()));
}

Frame response_frame(const Frame & request, Operation operation) {
    Frame response;
    response.operation = operation;
    std::memcpy(response.request_id, request.request_id, sizeof(response.request_id));
    response.generation = request.generation;
    return response;
}

bool write_error(const Frame & request, ErrorCategory category) {
    Frame response = response_frame(request, Operation::Error);
    response.payload.resize(4);
    write_u32(response.payload.data(), static_cast<uint32_t>(category));
    return write_frame(response);
}

uint16_t read_le_u16(const uint8_t * bytes) {
    return static_cast<uint16_t>(bytes[0] | (static_cast<uint16_t>(bytes[1]) << 8));
}

uint32_t read_le_u32(const uint8_t * bytes) {
    return static_cast<uint32_t>(bytes[0])
         | (static_cast<uint32_t>(bytes[1]) << 8)
         | (static_cast<uint32_t>(bytes[2]) << 16)
         | (static_cast<uint32_t>(bytes[3]) << 24);
}

bool read_pcm_wave(const std::string & path, std::vector<float> & samples) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) {
        return false;
    }
    const std::streamsize size = input.tellg();
    if (size < 44 || size > 256 * 1024 * 1024) {
        return false;
    }
    input.seekg(0, std::ios::beg);
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    if (!input.read(reinterpret_cast<char *>(bytes.data()), size)) {
        return false;
    }
    if (std::memcmp(bytes.data(), "RIFF", 4) != 0 || std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
        return false;
    }

    uint16_t format = 0;
    uint16_t channels = 0;
    uint32_t sample_rate = 0;
    uint16_t bits_per_sample = 0;
    const uint8_t * audio_data = nullptr;
    uint32_t audio_size = 0;

    size_t offset = 12;
    while (offset + 8 <= bytes.size()) {
        const uint8_t * chunk = bytes.data() + offset;
        const uint32_t chunk_size = read_le_u32(chunk + 4);
        const size_t content_offset = offset + 8;
        if (content_offset + chunk_size > bytes.size()) {
            return false;
        }
        if (std::memcmp(chunk, "fmt ", 4) == 0 && chunk_size >= 16) {
            const uint8_t * format_bytes = bytes.data() + content_offset;
            format = read_le_u16(format_bytes);
            channels = read_le_u16(format_bytes + 2);
            sample_rate = read_le_u32(format_bytes + 4);
            bits_per_sample = read_le_u16(format_bytes + 14);
        } else if (std::memcmp(chunk, "data", 4) == 0) {
            audio_data = bytes.data() + content_offset;
            audio_size = chunk_size;
        }
        offset = content_offset + chunk_size + (chunk_size & 1U);
    }

    if (format != 1 || channels != 1 || sample_rate != WHISPER_SAMPLE_RATE
        || bits_per_sample != 16 || audio_data == nullptr || (audio_size % 2) != 0) {
        return false;
    }

    const size_t sample_count = audio_size / 2;
    samples.resize(sample_count);
    for (size_t index = 0; index < sample_count; ++index) {
        const uint16_t raw = read_le_u16(audio_data + index * 2);
        const int16_t value = static_cast<int16_t>(raw);
        samples[index] = static_cast<float>(value) / 32768.0f;
    }
    return true;
}

bool parse_request(const Frame & frame, RequestConfiguration & request) {
    PayloadReader reader(frame.payload);
    uint32_t threads = 0;
    uint32_t beam_size = 0;
    uint32_t best_of = 0;
    uint32_t flags = 0;
    if (!reader.read_u32(threads) || !reader.read_u32(beam_size)
        || !reader.read_u32(best_of) || !reader.read_u32(flags)
        || !reader.read_string(request.audio_path)
        || !reader.read_string(request.language)
        || !reader.read_string(request.prompt, true)
        || !reader.read_string(request.suppress_regex, true)
        || !reader.read_string(request.vad_model_path, true)
        || !reader.exhausted()) {
        return false;
    }
    if (threads == 0 || threads > 128 || beam_size == 0 || beam_size > 128
        || best_of == 0 || best_of > 128 || (flags & ~0x3U) != 0) {
        return false;
    }
    request.threads = static_cast<int>(threads);
    request.beam_size = static_cast<int>(beam_size);
    request.best_of = static_cast<int>(best_of);
    request.suppress_non_speech_tokens = (flags & (1U << 0)) != 0;
    const bool vad_enabled = (flags & (1U << 1)) != 0;
    if (vad_enabled != !request.vad_model_path.empty()) {
        return false;
    }
    return !request.audio_path.empty() && !request.language.empty();
}

std::string json_escape(const char * value) {
    std::ostringstream output;
    const auto * bytes = reinterpret_cast<const unsigned char *>(value == nullptr ? "" : value);
    for (size_t index = 0; bytes[index] != 0; ++index) {
        const unsigned char byte = bytes[index];
        switch (byte) {
        case '\"': output << "\\\""; break;
        case '\\': output << "\\\\"; break;
        case '\b': output << "\\b"; break;
        case '\f': output << "\\f"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default:
            if (byte < 0x20) {
                static constexpr char kHex[] = "0123456789abcdef";
                output << "\\u00" << kHex[(byte >> 4) & 0xf] << kHex[byte & 0xf];
            } else {
                output << static_cast<char>(byte);
            }
        }
    }
    return output.str();
}

int centiseconds_to_samples(int64_t centiseconds) {
    return static_cast<int>((centiseconds / 100.0) * WHISPER_SAMPLE_RATE + 0.5);
}

int64_t samples_to_centiseconds(int samples) {
    return static_cast<int64_t>((samples / static_cast<double>(WHISPER_SAMPLE_RATE)) * 100.0 + 0.5);
}

int64_t map_processed_to_original_time(
    int64_t processed_time,
    const std::vector<TimeMapping> & mapping
) {
    if (mapping.empty()) {
        return processed_time;
    }
    if (processed_time <= mapping.front().processed_time) {
        return mapping.front().original_time;
    }
    if (processed_time >= mapping.back().processed_time) {
        return mapping.back().original_time;
    }

    const auto upper = std::lower_bound(
        mapping.begin(),
        mapping.end(),
        processed_time,
        [](const TimeMapping & entry, int64_t time) {
            return entry.processed_time < time;
        }
    );
    if (upper->processed_time == processed_time) {
        return upper->original_time;
    }

    const auto lower = upper - 1;
    const int64_t processed_difference = upper->processed_time - lower->processed_time;
    if (processed_difference == 0) {
        return lower->original_time;
    }
    const int64_t original_difference = upper->original_time - lower->original_time;
    const int64_t offset = processed_time - lower->processed_time;
    return lower->original_time + (offset * original_difference) / processed_difference;
}

std::string transcript_json(
    whisper_context * context,
    whisper_state * state,
    const std::vector<TimeMapping> & time_mapping
) {
    std::ostringstream output;
    output << "{\"transcription\":[";
    const int segment_count = whisper_full_n_segments_from_state(state);
    for (int segment_index = 0; segment_index < segment_count; ++segment_index) {
        if (segment_index > 0) {
            output << ',';
        }
        const int64_t processed_start = whisper_full_get_segment_t0_from_state(state, segment_index);
        const int64_t processed_end = whisper_full_get_segment_t1_from_state(state, segment_index);
        const int64_t segment_start = map_processed_to_original_time(processed_start, time_mapping);
        int64_t segment_end = map_processed_to_original_time(processed_end, time_mapping);
        if (!time_mapping.empty() && segment_end - segment_start < 10) {
            segment_end = segment_start + 10;
        }
        output << "{\"offsets\":{\"from\":" << segment_start * 10
               << ",\"to\":" << segment_end * 10
               << "},\"text\":\""
               << json_escape(whisper_full_get_segment_text_from_state(state, segment_index))
               << "\",\"tokens\":[";

        const int token_count = whisper_full_n_tokens_from_state(state, segment_index);
        for (int token_index = 0; token_index < token_count; ++token_index) {
            if (token_index > 0) {
                output << ',';
            }
            const whisper_token_data token = whisper_full_get_token_data_from_state(state, segment_index, token_index);
            output << "{\"text\":\"" << json_escape(whisper_token_to_str(context, token.id)) << "\"";
            if (token.t0 > -1 && token.t1 > -1) {
                output << ",\"offsets\":{\"from\":" << token.t0 * 10
                       << ",\"to\":" << token.t1 * 10 << '}';
            }
            output << ",\"id\":" << token.id << ",\"p\":" << token.p << '}';
        }
        output << "]}";
    }
    output << "]}";
    return output.str();
}

bool prepare_vad_audio(
    whisper_vad_context * vad_context,
    const whisper_vad_params & parameters,
    const std::vector<float> & input,
    PreparedAudio & prepared
) {
    std::unique_ptr<whisper_vad_segments, decltype(&whisper_vad_free_segments)> segments(
        whisper_vad_segments_from_samples(
            vad_context,
            parameters,
            input.data(),
            static_cast<int>(input.size())
        ),
        &whisper_vad_free_segments
    );
    if (segments == nullptr) {
        return false;
    }

    const int segment_count = whisper_vad_segments_n_segments(segments.get());
    if (segment_count == 0) {
        prepared.samples.clear();
        prepared.time_mapping.clear();
        prepared.speech_detected = false;
        return true;
    }

    struct Segment {
        int64_t start = 0;
        int64_t end = 0;
    };
    std::vector<Segment> detected;
    detected.reserve(static_cast<size_t>(segment_count));
    for (int index = 0; index < segment_count; ++index) {
        detected.push_back({
            static_cast<int64_t>(whisper_vad_segments_get_segment_t0(segments.get(), index)),
            static_cast<int64_t>(whisper_vad_segments_get_segment_t1(segments.get(), index)),
        });
    }

    const int sample_count = static_cast<int>(input.size());
    const int overlap_samples = static_cast<int>(parameters.samples_overlap * WHISPER_SAMPLE_RATE);
    int filtered_sample_count = 0;
    for (int index = 0; index < segment_count; ++index) {
        const int start = centiseconds_to_samples(detected[index].start);
        int end = centiseconds_to_samples(detected[index].end);
        if (index < segment_count - 1) {
            end += overlap_samples;
        }
        end = std::min(end, sample_count - 1);
        filtered_sample_count += end - start;
    }

    const int silence_samples = static_cast<int>(0.1 * WHISPER_SAMPLE_RATE);
    const int total_silence_samples = segment_count > 1
        ? (segment_count - 1) * silence_samples
        : 0;
    prepared.samples.resize(static_cast<size_t>(filtered_sample_count + total_silence_samples));
    prepared.time_mapping.clear();
    prepared.time_mapping.reserve(static_cast<size_t>(segment_count) * 4);
    prepared.speech_detected = true;

    int offset = 0;
    for (int index = 0; index < segment_count; ++index) {
        int start = centiseconds_to_samples(detected[index].start);
        int end = centiseconds_to_samples(detected[index].end);
        if (index < segment_count - 1) {
            end += overlap_samples;
        }
        start = std::min(start, sample_count - 1);
        end = std::min(end, sample_count - 1);
        const int length = end - start;
        if (length <= 0) {
            continue;
        }

        const int64_t vad_start = samples_to_centiseconds(offset);
        const int64_t vad_end = samples_to_centiseconds(offset + length);
        prepared.time_mapping.push_back({vad_start, detected[index].start});
        prepared.time_mapping.push_back({vad_end, detected[index].end});

        constexpr int64_t minimum_segment_length = 100;
        constexpr int64_t point_interval = 20;
        if (vad_end - vad_start > minimum_segment_length) {
            const int64_t duration = vad_end - vad_start;
            const int point_count = static_cast<int>(duration / point_interval) - 1;
            for (int point = 1; point <= point_count; ++point) {
                const int64_t vad_time = vad_start + point * point_interval;
                if (vad_time >= vad_end) {
                    continue;
                }
                const int64_t vad_elapsed = vad_time - vad_start;
                const int64_t vad_total = vad_end - vad_start;
                const int64_t original_total = detected[index].end - detected[index].start;
                const int64_t original_time = detected[index].start
                    + (vad_elapsed * original_total) / vad_total;
                prepared.time_mapping.push_back({vad_time, original_time});
            }
        }

        std::memcpy(
            prepared.samples.data() + offset,
            input.data() + start,
            static_cast<size_t>(length) * sizeof(float)
        );
        offset += length;

        if (index < segment_count - 1) {
            const int64_t silence_start = samples_to_centiseconds(offset);
            const int64_t silence_end = samples_to_centiseconds(offset + silence_samples);
            prepared.time_mapping.push_back({silence_start, detected[index].end});
            prepared.time_mapping.push_back({silence_end, detected[index + 1].start});
            std::memset(
                prepared.samples.data() + offset,
                0,
                static_cast<size_t>(silence_samples) * sizeof(float)
            );
            offset += silence_samples;
        }
    }

    prepared.samples.resize(static_cast<size_t>(offset));
    std::sort(
        prepared.time_mapping.begin(),
        prepared.time_mapping.end(),
        [](const TimeMapping & lhs, const TimeMapping & rhs) {
            return lhs.processed_time < rhs.processed_time;
        }
    );
    const auto unique_end = std::unique(
        prepared.time_mapping.begin(),
        prepared.time_mapping.end(),
        [](const TimeMapping & lhs, const TimeMapping & rhs) {
            return lhs.processed_time == rhs.processed_time;
        }
    );
    prepared.time_mapping.erase(unique_end, prepared.time_mapping.end());
    return true;
}

bool transcribe(
    whisper_context * context,
    whisper_vad_context *& vad_context,
    std::string & loaded_vad_model_path,
    const RequestConfiguration & request,
    std::string & output_json
) {
    if (request.language != "auto" && whisper_lang_id(request.language.c_str()) == -1) {
        return false;
    }

    std::vector<float> samples;
    if (!read_pcm_wave(request.audio_path, samples)) {
        return false;
    }

    whisper_full_params parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    parameters.strategy = request.beam_size > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY;
    parameters.n_threads = request.threads;
    parameters.no_context = true;
    parameters.no_timestamps = true;
    parameters.token_timestamps = true;
    parameters.print_realtime = false;
    parameters.print_progress = false;
    parameters.print_timestamps = false;
    parameters.print_special = false;
    const char * language = whisper_is_multilingual(context) ? request.language.c_str() : "en";
    parameters.language = language;
    parameters.initial_prompt = request.prompt.c_str();
    parameters.suppress_regex = request.suppress_regex.empty() ? nullptr : request.suppress_regex.c_str();
    parameters.suppress_nst = request.suppress_non_speech_tokens;
    parameters.greedy.best_of = request.best_of;
    parameters.beam_search.beam_size = request.beam_size;
    parameters.temperature = 0.0f;
    parameters.temperature_inc = 0.2f;
    parameters.entropy_thold = 2.4f;
    parameters.logprob_thold = -1.0f;
    parameters.no_speech_thold = 0.6f;
    parameters.vad = false;
    parameters.vad_model_path = nullptr;
    parameters.vad_params.threshold = 0.5f;
    parameters.vad_params.min_speech_duration_ms = 250;
    parameters.vad_params.min_silence_duration_ms = 100;
    parameters.vad_params.max_speech_duration_s = FLT_MAX;
    parameters.vad_params.speech_pad_ms = 30;
    parameters.vad_params.samples_overlap = 0.1f;

    PreparedAudio prepared;
    if (!request.vad_model_path.empty()) {
        if (vad_context == nullptr || loaded_vad_model_path != request.vad_model_path) {
            if (vad_context != nullptr) {
                whisper_vad_free(vad_context);
                vad_context = nullptr;
            }
            const whisper_vad_context_params vad_context_parameters = whisper_vad_default_context_params();
            vad_context = whisper_vad_init_from_file_with_params(
                request.vad_model_path.c_str(),
                vad_context_parameters
            );
            if (vad_context == nullptr) {
                loaded_vad_model_path.clear();
                return false;
            }
            loaded_vad_model_path = request.vad_model_path;
        }
        if (!prepare_vad_audio(vad_context, parameters.vad_params, samples, prepared)) {
            return false;
        }
    } else {
        prepared.samples = std::move(samples);
    }

    std::unique_ptr<whisper_state, decltype(&whisper_free_state)> state(
        whisper_init_state(context),
        &whisper_free_state
    );
    if (state == nullptr) {
        return false;
    }
    if (prepared.speech_detected
        && whisper_full_with_state(
            context,
            state.get(),
            parameters,
            prepared.samples.data(),
            static_cast<int>(prepared.samples.size())
        ) != 0) {
        return false;
    }
    output_json = transcript_json(context, state.get(), prepared.time_mapping);
    return output_json.size() <= kMaximumPayloadBytes;
}

void start_parent_monitor() {
    const char * raw_parent = std::getenv("STENO_PARENT_PID");
    if (raw_parent == nullptr) {
        return;
    }
    char * end = nullptr;
    const long parsed = std::strtol(raw_parent, &end, 10);
    if (end == raw_parent || *end != '\0' || parsed <= 1) {
        return;
    }
    const pid_t expected_parent = static_cast<pid_t>(parsed);
    std::thread([expected_parent] {
        if (getppid() != expected_parent) {
            _exit(0);
        }

        const int queue = kqueue();
        if (queue < 0) {
            _exit(0);
        }
        struct kevent change = {};
        EV_SET(
            &change,
            static_cast<uintptr_t>(expected_parent),
            EVFILT_PROC,
            EV_ADD | EV_ENABLE | EV_ONESHOT,
            NOTE_EXIT,
            0,
            nullptr
        );
        if (kevent(queue, &change, 1, nullptr, 0, nullptr) < 0
            || getppid() != expected_parent) {
            close(queue);
            _exit(0);
        }

        struct kevent event = {};
        (void) kevent(queue, nullptr, 0, &event, 1, nullptr);
        close(queue);
        _exit(0);
    }).detach();
}

bool valid_arguments(int argc, char ** argv) {
    return argc == 3
        && std::strcmp(argv[1], "--protocol-version") == 0
        && std::strcmp(argv[2], "1") == 0;
}

} // namespace

int main(int argc, char ** argv) {
    if (!valid_arguments(argc, argv)) {
        return 64;
    }

    whisper_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    start_parent_monitor();

    Frame load_request;
    if (!read_frame(load_request) || load_request.operation != Operation::Load) {
        return 65;
    }
    PayloadReader load_reader(load_request.payload);
    std::string model_path;
    if (!load_reader.read_string(model_path) || !load_reader.exhausted() || model_path.empty()) {
        write_error(load_request, ErrorCategory::Protocol);
        return 65;
    }

    whisper_context * context = nullptr;
    try {
        whisper_context_params context_parameters = whisper_context_default_params();
        context_parameters.use_gpu = true;
        context_parameters.flash_attn = true;
        context = whisper_init_from_file_with_params_no_state(model_path.c_str(), context_parameters);
    } catch (...) {
        context = nullptr;
    }
    if (context == nullptr) {
        write_error(load_request, ErrorCategory::ModelLoad);
        return 66;
    }

    if (!write_frame(response_frame(load_request, Operation::Ready))) {
        whisper_free(context);
        return 67;
    }

    whisper_vad_context * vad_context = nullptr;
    std::string loaded_vad_model_path;
    int exit_code = 0;
    for (;;) {
        Frame request;
        if (!read_frame(request)) {
            break;
        }
        if (request.operation == Operation::Shutdown) {
            if (vad_context != nullptr) {
                whisper_vad_free(vad_context);
                vad_context = nullptr;
            }
            whisper_free(context);
            context = nullptr;
            return write_frame(response_frame(request, Operation::Stopped)) ? 0 : 67;
        }
        if (request.operation != Operation::Transcribe) {
            write_error(request, ErrorCategory::Protocol);
            exit_code = 65;
            break;
        }

        RequestConfiguration configuration;
        if (!parse_request(request, configuration)) {
            write_error(request, ErrorCategory::Protocol);
            continue;
        }

        std::string json;
        bool succeeded = false;
        try {
            succeeded = transcribe(
                context,
                vad_context,
                loaded_vad_model_path,
                configuration,
                json
            );
        } catch (...) {
            succeeded = false;
        }
        if (!succeeded) {
            write_error(request, ErrorCategory::Inference);
            continue;
        }

        Frame response = response_frame(request, Operation::Result);
        response.payload.assign(json.begin(), json.end());
        if (!write_frame(response)) {
            exit_code = 67;
            break;
        }
    }

    if (vad_context != nullptr) {
        whisper_vad_free(vad_context);
    }
    if (context != nullptr) {
        whisper_free(context);
    }
    return exit_code;
}
