#include "whisper.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cfloat>
#include <cerrno>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>
#include <sys/event.h>

namespace {

constexpr uint32_t kMagic = 0x53545752;
constexpr uint16_t kVersion1 = 1;
constexpr uint16_t kVersion2 = 2;
constexpr uint32_t kMaximumPayloadBytes = 64U * 1024U * 1024U;
constexpr uint32_t kMaximumStringBytes = 1024U * 1024U;
constexpr uint32_t kMaximumAudioAppendBytes = 32U * 1024U;
constexpr uint32_t kMaximumHypothesisBytes = 1024U * 1024U;
constexpr size_t kPreviewWindowSamples = 12U * WHISPER_SAMPLE_RATE;
constexpr uint64_t kMaximumStreamSamples = 12ULL * 60ULL * 60ULL * WHISPER_SAMPLE_RATE;
constexpr uint64_t kFNV1aOffsetBasis = 14695981039346656037ULL;
constexpr uint64_t kFNV1aPrime = 1099511628211ULL;

enum class ObservedBackend : int {
    Unknown = 0,
    CPU = 1,
    Metal = 2,
};

std::atomic<ObservedBackend> g_observed_backend{ObservedBackend::Unknown};
uint32_t g_current_asr_context_count = 0;
uint32_t g_peak_asr_context_count = 0;

void record_asr_context_constructed() {
    ++g_current_asr_context_count;
    g_peak_asr_context_count = std::max(
        g_peak_asr_context_count,
        g_current_asr_context_count
    );
}

void free_asr_context(whisper_context * context) {
    if (context == nullptr) {
        return;
    }
    whisper_free(context);
    --g_current_asr_context_count;
}

void observe_backend_log(ggml_log_level, const char * message, void *) {
    if (message == nullptr) {
        return;
    }
    if (std::strstr(message, "found GPU device") != nullptr) {
        g_observed_backend.store(ObservedBackend::Metal, std::memory_order_relaxed);
    } else if (std::strstr(message, "no GPU found") != nullptr
        || std::strstr(message, "failed to initialize") != nullptr) {
        g_observed_backend.store(ObservedBackend::CPU, std::memory_order_relaxed);
    }
}
constexpr uint32_t kIdentitySchemaVersion = 2;
// streaming | identity acknowledgements | cooperative cancellation |
// terminal acknowledgements | preview speech evidence | correlated errors |
// ASR context telemetry
constexpr uint32_t kRuntimeCapabilities = 0x7f;
constexpr size_t kMaximumIdentityBytes = 128;

// Frame headers and integer payload fields use network byte order. AudioAppend
// carries little-endian signed 16-bit mono PCM because it mirrors the WAV data.
// Length-prefixed strings use a UInt32 byte count; UINT32_MAX represents nil.
enum class Operation : uint16_t {
    Load = 1,
    Ready = 2,
    Transcribe = 3,
    Result = 4,
    Error = 5,
    Shutdown = 6,
    Stopped = 7,
    Cancelled = 8,
    StreamStart = 9,
    StreamStarted = 10,
    AudioAppend = 11,
    AudioAccepted = 12,
    StreamDecode = 13,
    Hypothesis = 14,
    StreamFinish = 15,
    FinalResult = 16,
    StreamCancel = 17,
};

enum class ErrorCategory : uint32_t {
    Protocol = 1,
    ModelLoad = 2,
    Audio = 3,
    Inference = 4,
    Internal = 5,
};

enum class PreviewSpeechEvidence : uint32_t {
    Unknown = 0,
    NoSpeech = 1,
    Speech = 2,
};

struct Frame {
    uint16_t version = kVersion1;
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
    std::string vad_identity;
};

struct RuntimeIdentity {
    std::string runtime;
    std::string model;
    std::string vad;
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

    bool read_u64(uint64_t & value) {
        if (offset_ + 8 > data_.size()) {
            return false;
        }
        value = 0;
        for (int index = 0; index < 8; ++index) {
            value = (value << 8) | data_[offset_ + static_cast<size_t>(index)];
        }
        offset_ += 8;
        return true;
    }

    bool read_bytes(size_t count, const uint8_t *& value) {
        if (count > data_.size() - offset_) {
            return false;
        }
        value = data_.data() + offset_;
        offset_ += count;
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

bool read_frame(Frame & frame, uint16_t expected_version) {
    uint8_t header[36] = {};
    if (!read_exact(STDIN_FILENO, header, sizeof(header))) {
        return false;
    }
    const uint16_t version = read_u16(header + 4);
    if (read_u32(header) != kMagic || version != expected_version) {
        return false;
    }
    const auto raw_operation = read_u16(header + 6);
    const uint16_t maximum_operation = version == kVersion1
        ? static_cast<uint16_t>(Operation::Cancelled)
        : static_cast<uint16_t>(Operation::StreamCancel);
    if (raw_operation < static_cast<uint16_t>(Operation::Load)
        || raw_operation > maximum_operation) {
        return false;
    }
    frame.version = version;
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
    write_u16(header + 4, frame.version);
    write_u16(header + 6, static_cast<uint16_t>(frame.operation));
    std::memcpy(header + 8, frame.request_id, sizeof(frame.request_id));
    write_u64(header + 24, frame.generation);
    write_u32(header + 32, static_cast<uint32_t>(frame.payload.size()));
    return write_exact(STDOUT_FILENO, header, sizeof(header))
        && (frame.payload.empty() || write_exact(STDOUT_FILENO, frame.payload.data(), frame.payload.size()));
}

Frame response_frame(const Frame & request, Operation operation) {
    Frame response;
    response.version = request.version;
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

bool read_pcm_wave_bytes(const std::string & path, std::vector<uint8_t> & pcm_bytes) {
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

    pcm_bytes.assign(audio_data, audio_data + audio_size);
    return true;
}

bool read_pcm_wave(const std::string & path, std::vector<float> & samples) {
    std::vector<uint8_t> pcm_bytes;
    if (!read_pcm_wave_bytes(path, pcm_bytes)) {
        return false;
    }
    const size_t sample_count = pcm_bytes.size() / 2;
    samples.resize(sample_count);
    for (size_t index = 0; index < sample_count; ++index) {
        const uint16_t raw = read_le_u16(pcm_bytes.data() + index * 2);
        const int16_t value = static_cast<int16_t>(raw);
        samples[index] = static_cast<float>(value) / 32768.0f;
    }
    return true;
}

uint64_t fnv1a_update(uint64_t hash, const uint8_t * bytes, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        hash ^= bytes[index];
        hash *= kFNV1aPrime;
    }
    return hash;
}

bool is_opaque_identity(const std::string & value, bool permits_empty);

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

bool parse_stream_configuration(PayloadReader & reader, RequestConfiguration & request) {
    uint32_t threads = 0;
    uint32_t beam_size = 0;
    uint32_t best_of = 0;
    uint32_t flags = 0;
    if (!reader.read_u32(threads) || !reader.read_u32(beam_size)
        || !reader.read_u32(best_of) || !reader.read_u32(flags)
        || !reader.read_string(request.language)
        || !reader.read_string(request.prompt, true)
        || !reader.read_string(request.suppress_regex, true)
        || !reader.read_string(request.vad_model_path, true)
        || !reader.read_string(request.vad_identity)) {
        return false;
    }
    if (threads == 0 || threads > 128 || beam_size == 0 || beam_size > 128
        || best_of == 0 || best_of > 128 || (flags & ~0x3U) != 0
        || request.language.empty()) {
        return false;
    }
    request.threads = static_cast<int>(threads);
    request.beam_size = static_cast<int>(beam_size);
    request.best_of = static_cast<int>(best_of);
    request.suppress_non_speech_tokens = (flags & (1U << 0)) != 0;
    const bool vad_enabled = (flags & (1U << 1)) != 0;
    return vad_enabled == !request.vad_model_path.empty()
        && vad_enabled == !request.vad_identity.empty()
        && is_opaque_identity(request.vad_identity, true);
}

void append_u32(std::vector<uint8_t> & payload, uint32_t value) {
    const size_t offset = payload.size();
    payload.resize(offset + 4);
    write_u32(payload.data() + offset, value);
}

void append_u16(std::vector<uint8_t> & payload, uint16_t value) {
    const size_t offset = payload.size();
    payload.resize(offset + 2);
    write_u16(payload.data() + offset, value);
}

void append_u64(std::vector<uint8_t> & payload, uint64_t value) {
    const size_t offset = payload.size();
    payload.resize(offset + 8);
    write_u64(payload.data() + offset, value);
}

void append_string(std::vector<uint8_t> & payload, const std::string & value) {
    append_u32(payload, static_cast<uint32_t>(value.size()));
    payload.insert(payload.end(), value.begin(), value.end());
}

bool is_opaque_identity(const std::string & value, bool permits_empty = false) {
    if (value.empty()) {
        return permits_empty;
    }
    if (value.size() > kMaximumIdentityBytes) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char byte) {
        return (byte >= 'a' && byte <= 'z')
            || (byte >= 'A' && byte <= 'Z')
            || (byte >= '0' && byte <= '9')
            || byte == '-';
    });
}

void append_identity_payload(
    std::vector<uint8_t> & payload,
    const RuntimeIdentity & identity
) {
    append_u32(payload, kIdentitySchemaVersion);
    append_u32(payload, kRuntimeCapabilities);
    append_string(payload, identity.runtime);
    append_string(payload, identity.model);
    append_string(payload, identity.vad);
    append_u32(payload, g_current_asr_context_count);
    append_u32(payload, g_peak_asr_context_count);
}

bool same_request_identity(const Frame & lhs, const Frame & rhs) {
    return lhs.generation == rhs.generation
        && std::memcmp(lhs.request_id, rhs.request_id, sizeof(lhs.request_id)) == 0;
}

uint64_t monotonic_nanoseconds() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()
    ).count());
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
    std::string & output_json,
    std::atomic<bool> * abort_requested = nullptr,
    const std::vector<uint8_t> * pcm_snapshot = nullptr
) {
    if (request.language != "auto" && whisper_lang_id(request.language.c_str()) == -1) {
        return false;
    }

    std::vector<float> samples;
    if (pcm_snapshot != nullptr) {
        if ((pcm_snapshot->size() % 2) != 0) {
            return false;
        }
        samples.resize(pcm_snapshot->size() / 2);
        for (size_t index = 0; index < samples.size(); ++index) {
            samples[index] = static_cast<float>(static_cast<int16_t>(
                read_le_u16(pcm_snapshot->data() + index * 2)
            )) / 32768.0f;
        }
    } else if (!read_pcm_wave(request.audio_path, samples)) {
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
    if (abort_requested != nullptr) {
        parameters.abort_callback = [](void * user_data) {
            return static_cast<std::atomic<bool> *>(user_data)->load(std::memory_order_relaxed);
        };
        parameters.abort_callback_user_data = abort_requested;
    }

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

bool transcribe_preview(
    whisper_context * context,
    const RequestConfiguration & request,
    const std::vector<int16_t> & pcm,
    std::atomic<bool> & abort_requested,
    std::string & text
) {
    if (request.language != "auto" && whisper_lang_id(request.language.c_str()) == -1) {
        return false;
    }
    std::vector<float> samples(pcm.size());
    for (size_t index = 0; index < pcm.size(); ++index) {
        samples[index] = static_cast<float>(pcm[index]) / 32768.0f;
    }

    whisper_full_params parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    parameters.strategy = request.beam_size > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY;
    parameters.n_threads = request.threads;
    parameters.no_context = true;
    parameters.no_timestamps = true;
    parameters.token_timestamps = false;
    parameters.single_segment = false;
    parameters.print_realtime = false;
    parameters.print_progress = false;
    parameters.print_timestamps = false;
    parameters.print_special = false;
    parameters.language = whisper_is_multilingual(context) ? request.language.c_str() : "en";
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
    parameters.abort_callback = [](void * user_data) {
        return static_cast<std::atomic<bool> *>(user_data)->load(std::memory_order_relaxed);
    };
    parameters.abort_callback_user_data = &abort_requested;

    std::unique_ptr<whisper_state, decltype(&whisper_free_state)> state(
        whisper_init_state(context),
        &whisper_free_state
    );
    if (state == nullptr) {
        return false;
    }
    if (!samples.empty()
        && whisper_full_with_state(
            context,
            state.get(),
            parameters,
            samples.data(),
            static_cast<int>(samples.size())
        ) != 0) {
        return false;
    }
    std::ostringstream output;
    const int segment_count = whisper_full_n_segments_from_state(state.get());
    for (int index = 0; index < segment_count; ++index) {
        output << whisper_full_get_segment_text_from_state(state.get(), index);
        if (output.tellp() > static_cast<std::streampos>(kMaximumHypothesisBytes)) {
            return false;
        }
    }
    text = output.str();
    return text.size() <= kMaximumHypothesisBytes;
}

bool detect_preview_speech(
    whisper_vad_context *& vad_context,
    std::string & loaded_vad_model_path,
    const RequestConfiguration & request,
    const std::vector<int16_t> & pcm,
    std::atomic<bool> & abort_requested,
    PreviewSpeechEvidence & evidence
) {
    evidence = PreviewSpeechEvidence::Unknown;
    if (request.vad_model_path.empty()) {
        return true;
    }
    if (abort_requested.load(std::memory_order_relaxed)) {
        return false;
    }
    if (vad_context == nullptr || loaded_vad_model_path != request.vad_model_path) {
        if (vad_context != nullptr) {
            whisper_vad_free(vad_context);
            vad_context = nullptr;
        }
        const whisper_vad_context_params context_parameters = whisper_vad_default_context_params();
        vad_context = whisper_vad_init_from_file_with_params(
            request.vad_model_path.c_str(),
            context_parameters
        );
        if (vad_context == nullptr) {
            loaded_vad_model_path.clear();
            return false;
        }
        loaded_vad_model_path = request.vad_model_path;
    }
    if (pcm.empty()) {
        evidence = PreviewSpeechEvidence::NoSpeech;
        return !abort_requested.load(std::memory_order_relaxed);
    }

    std::vector<float> samples(pcm.size());
    for (size_t index = 0; index < pcm.size(); ++index) {
        samples[index] = static_cast<float>(pcm[index]) / 32768.0f;
    }
    whisper_vad_params parameters = whisper_vad_default_params();
    parameters.threshold = 0.12f;
    // Preview evidence is decode-scoped and must qualify before the canonical
    // final-transcription VAD gate runs. A 50 ms minimum admits sustained
    // early speech split across a 200 ms scheduling boundary while still rejecting
    // shorter transients. The lower preview-only threshold admits the public
    // JFK onset, whose short-window probability remains below the canonical
    // 0.5 threshold; final transcription retains its 0.5/250 ms gate.
    parameters.min_speech_duration_ms = 50;
    parameters.min_silence_duration_ms = 100;
    parameters.max_speech_duration_s = FLT_MAX;
    parameters.speech_pad_ms = 30;
    parameters.samples_overlap = 0.1f;
    PreparedAudio prepared;
    if (!prepare_vad_audio(vad_context, parameters, samples, prepared)
        || abort_requested.load(std::memory_order_relaxed)) {
        return false;
    }
    evidence = prepared.speech_detected
        ? PreviewSpeechEvidence::Speech
        : PreviewSpeechEvidence::NoSpeech;
    return true;
}

int run_version_1(whisper_context * context) {
    whisper_vad_context * vad_context = nullptr;
    std::string loaded_vad_model_path;
    int exit_code = 0;
    for (;;) {
        Frame request;
        if (!read_frame(request, kVersion1)) {
            break;
        }
        if (request.operation == Operation::Shutdown) {
            if (vad_context != nullptr) {
                whisper_vad_free(vad_context);
            }
            free_asr_context(context);
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
    free_asr_context(context);
    return exit_code;
}

struct PreviewRequest {
    Frame frame;
    uint64_t revision = 0;
    uint64_t watermark = 0;
    RequestConfiguration configuration;
    std::vector<int16_t> samples;
    std::vector<int16_t> evidence_samples;
};

struct FinalRequest {
    Frame frame;
    uint64_t expected_samples = 0;
    uint64_t expected_hash = kFNV1aOffsetBasis;
    uint64_t streamed_samples = 0;
    uint64_t streamed_hash = kFNV1aOffsetBasis;
    bool streamed_accounting_valid = true;
    RequestConfiguration configuration;
};

struct OneShotRequest {
    Frame frame;
    RequestConfiguration configuration;
};

struct StreamRuntime {
    std::mutex mutex;
    std::condition_variable condition;
    std::mutex writer_mutex;
    Frame session;
    RequestConfiguration preview_configuration;
    std::vector<int16_t> rolling_samples;
    uint64_t next_sequence = 0;
    uint64_t total_samples = 0;
    uint64_t last_revision = 0;
    uint64_t last_decode_watermark = 0;
    uint64_t audio_hash = kFNV1aOffsetBasis;
    bool active = false;
    bool finishing = false;
    bool preview_enabled = true;
    bool streamed_accounting_valid = true;
    bool one_shot_active = false;
    bool shutdown = false;
    std::optional<PreviewRequest> pending_preview;
    std::optional<FinalRequest> pending_final;
    std::optional<OneShotRequest> pending_one_shot;
    std::atomic<bool> abort_requested{false};
};

bool write_stream_frame(StreamRuntime & runtime, const Frame & frame) {
    std::lock_guard<std::mutex> lock(runtime.writer_mutex);
    return write_frame(frame);
}

bool write_stream_error(StreamRuntime & runtime, const Frame & frame, ErrorCategory category) {
    Frame response = response_frame(frame, Operation::Error);
    append_u32(response.payload, static_cast<uint32_t>(category));
    append_u16(response.payload, static_cast<uint16_t>(frame.operation));
    append_u16(response.payload, 0);
    uint64_t discriminator = std::numeric_limits<uint64_t>::max();
    if ((frame.operation == Operation::AudioAppend
            || frame.operation == Operation::StreamDecode)
        && frame.payload.size() >= sizeof(uint64_t)) {
        discriminator = read_u64(frame.payload.data());
    }
    append_u64(response.payload, discriminator);
    return write_stream_frame(runtime, response);
}

bool valid_stream_identity(const StreamRuntime & runtime, const Frame & frame) {
    return runtime.active
        && same_request_identity(runtime.session, frame);
}

void streaming_worker(whisper_context * context, StreamRuntime & runtime) {
    whisper_vad_context * vad_context = nullptr;
    std::string loaded_vad_model_path;
    for (;;) {
        std::optional<PreviewRequest> preview;
        std::optional<FinalRequest> final_request;
        std::optional<OneShotRequest> one_shot;
        {
            std::unique_lock<std::mutex> lock(runtime.mutex);
            runtime.condition.wait(lock, [&] {
                return runtime.shutdown || runtime.pending_final.has_value()
                    || runtime.pending_one_shot.has_value()
                    || runtime.pending_preview.has_value();
            });
            if (runtime.shutdown) {
                break;
            }
            if (runtime.pending_final.has_value()) {
                final_request = std::move(runtime.pending_final);
                runtime.pending_final.reset();
                runtime.pending_preview.reset();
            } else if (runtime.pending_one_shot.has_value()) {
                one_shot = std::move(runtime.pending_one_shot);
                runtime.pending_one_shot.reset();
            } else {
                preview = std::move(runtime.pending_preview);
                runtime.pending_preview.reset();
            }
            runtime.abort_requested.store(false, std::memory_order_relaxed);
        }

        if (one_shot.has_value()) {
            std::string json;
            bool succeeded = false;
            try {
                succeeded = transcribe(
                    context,
                    vad_context,
                    loaded_vad_model_path,
                    one_shot->configuration,
                    json,
                    &runtime.abort_requested
                );
            } catch (...) {
                succeeded = false;
            }
            bool should_respond = false;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                should_respond = !runtime.shutdown;
                runtime.one_shot_active = false;
            }
            if (should_respond) {
                if (!succeeded) {
                    write_stream_error(runtime, one_shot->frame, ErrorCategory::Inference);
                } else {
                    Frame response = response_frame(one_shot->frame, Operation::Result);
                    response.payload.assign(json.begin(), json.end());
                    write_stream_frame(runtime, response);
                }
            }
            continue;
        }

        if (final_request.has_value()) {
            std::vector<uint8_t> canonical_pcm;
            bool canonical_matches = read_pcm_wave_bytes(
                final_request->configuration.audio_path,
                canonical_pcm
            );
            const uint64_t canonical_samples = canonical_pcm.size() / 2;
            const uint64_t canonical_hash = fnv1a_update(
                kFNV1aOffsetBasis,
                canonical_pcm.data(),
                canonical_pcm.size()
            );
            canonical_matches = canonical_matches
                && canonical_samples == final_request->expected_samples
                && canonical_hash == final_request->expected_hash
                && final_request->streamed_accounting_valid
                && final_request->streamed_samples == final_request->expected_samples
                && final_request->streamed_hash == final_request->expected_hash;
            std::string json;
            bool succeeded = false;
            if (canonical_matches) {
                try {
                    succeeded = transcribe(
                        context,
                        vad_context,
                        loaded_vad_model_path,
                        final_request->configuration,
                        json,
                        &runtime.abort_requested,
                        &canonical_pcm
                    );
                } catch (...) {
                    succeeded = false;
                }
            }

            bool should_respond = false;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                should_respond = !runtime.shutdown
                    && runtime.active
                    && same_request_identity(runtime.session, final_request->frame);
                if (should_respond) {
                    runtime.active = false;
                    runtime.finishing = false;
                    runtime.rolling_samples.clear();
                }
            }
            if (should_respond) {
                if (!canonical_matches) {
                    write_stream_error(runtime, final_request->frame, ErrorCategory::Audio);
                } else if (!succeeded) {
                    write_stream_error(runtime, final_request->frame, ErrorCategory::Inference);
                } else {
                    Frame response = response_frame(final_request->frame, Operation::FinalResult);
                    response.payload.assign(json.begin(), json.end());
                    write_stream_frame(runtime, response);
                }
            }
            continue;
        }

        std::string text;
        PreviewSpeechEvidence speech_evidence = PreviewSpeechEvidence::Unknown;
        bool succeeded = false;
        try {
            succeeded = detect_preview_speech(
                vad_context,
                loaded_vad_model_path,
                preview->configuration,
                preview->evidence_samples,
                runtime.abort_requested,
                speech_evidence
            );
            if (succeeded && !runtime.abort_requested.load(std::memory_order_relaxed)) {
                succeeded = transcribe_preview(
                    context,
                    preview->configuration,
                    preview->samples,
                    runtime.abort_requested,
                    text
                );
            }
        } catch (...) {
            succeeded = false;
        }
        bool response_allowed = false;
        {
            std::lock_guard<std::mutex> lock(runtime.mutex);
            response_allowed = preview.has_value()
                && !runtime.shutdown
                && runtime.active
                && !runtime.finishing
                && runtime.preview_enabled
                && same_request_identity(runtime.session, preview->frame);
        }
        if (response_allowed) {
            if (!succeeded) {
                write_stream_error(runtime, preview->frame, ErrorCategory::Inference);
            } else {
                Frame response = response_frame(preview->frame, Operation::Hypothesis);
                append_u64(response.payload, preview->revision);
                append_u64(response.payload, preview->watermark);
                append_u64(response.payload, monotonic_nanoseconds());
                append_u32(response.payload, static_cast<uint32_t>(speech_evidence));
                append_string(response.payload, text);
                write_stream_frame(runtime, response);
            }
        }
    }
    if (vad_context != nullptr) {
        whisper_vad_free(vad_context);
    }
}

int run_version_2(
    whisper_context * context,
    const Frame & load_request,
    const RuntimeIdentity & identity
) {
    StreamRuntime runtime;
    runtime.session.version = kVersion2;
    runtime.rolling_samples.reserve(kPreviewWindowSamples);
    (void) load_request;
    std::thread worker(streaming_worker, context, std::ref(runtime));
    int exit_code = 0;
    std::optional<Frame> shutdown_request;

    for (;;) {
        Frame request;
        if (!read_frame(request, kVersion2)) {
            exit_code = 65;
            break;
        }
        if (request.operation == Operation::Shutdown) {
            if (!request.payload.empty() || request.generation != 0) {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
                continue;
            }
            shutdown_request = request;
            break;
        }

        if (request.operation == Operation::StreamStart) {
            PayloadReader reader(request.payload);
            RequestConfiguration configuration;
            if (!parse_stream_configuration(reader, configuration)
                || !reader.exhausted()
                || configuration.vad_identity != identity.vad) {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
                continue;
            }
            bool accepted = false;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                if (!runtime.active && !runtime.one_shot_active) {
                    runtime.session = request;
                    runtime.preview_configuration = std::move(configuration);
                    runtime.rolling_samples.clear();
                    runtime.next_sequence = 0;
                    runtime.total_samples = 0;
                    runtime.last_revision = 0;
                    runtime.last_decode_watermark = 0;
                    runtime.audio_hash = kFNV1aOffsetBasis;
                    runtime.active = true;
                    runtime.finishing = false;
                    runtime.preview_enabled = true;
                    runtime.streamed_accounting_valid = true;
                    runtime.pending_preview.reset();
                    runtime.pending_final.reset();
                    accepted = true;
                }
            }
            if (accepted) {
                Frame response = response_frame(request, Operation::StreamStarted);
                append_identity_payload(response.payload, identity);
                write_stream_frame(runtime, response);
            } else {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
            }
            continue;
        }

        if (request.operation == Operation::Transcribe) {
            RequestConfiguration configuration;
            const bool parsed = parse_request(request, configuration);
            bool accepted = false;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                if (parsed && !runtime.active && !runtime.one_shot_active) {
                    runtime.one_shot_active = true;
                    runtime.pending_one_shot = OneShotRequest{request, std::move(configuration)};
                    runtime.condition.notify_one();
                    accepted = true;
                }
            }
            if (!accepted) {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
            }
            continue;
        }

        if (request.operation == Operation::AudioAppend) {
            PayloadReader reader(request.payload);
            uint64_t sequence = 0;
            uint64_t sample_offset = 0;
            uint32_t sample_count = 0;
            const uint8_t * pcm_bytes = nullptr;
            const bool parsed = reader.read_u64(sequence)
                && reader.read_u64(sample_offset)
                && reader.read_u32(sample_count)
                && sample_count > 0
                && sample_count <= kMaximumAudioAppendBytes / 2
                && reader.read_bytes(static_cast<size_t>(sample_count) * 2, pcm_bytes)
                && reader.exhausted();
            bool accepted = false;
            uint64_t watermark = 0;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                if (parsed && valid_stream_identity(runtime, request)
                    && !runtime.finishing
                    && sequence == runtime.next_sequence
                    && sample_offset == runtime.total_samples
                    && runtime.total_samples <= kMaximumStreamSamples - sample_count) {
                    runtime.audio_hash = fnv1a_update(
                        runtime.audio_hash,
                        pcm_bytes,
                        static_cast<size_t>(sample_count) * 2
                    );
                    runtime.total_samples += sample_count;
                    runtime.next_sequence += 1;
                    watermark = runtime.total_samples;
                    const size_t old_size = runtime.rolling_samples.size();
                    runtime.rolling_samples.resize(old_size + sample_count);
                    for (uint32_t index = 0; index < sample_count; ++index) {
                        runtime.rolling_samples[old_size + index] = static_cast<int16_t>(
                            read_le_u16(pcm_bytes + static_cast<size_t>(index) * 2)
                        );
                    }
                    if (runtime.rolling_samples.size() > kPreviewWindowSamples) {
                        const size_t excess = runtime.rolling_samples.size() - kPreviewWindowSamples;
                        runtime.rolling_samples.erase(
                            runtime.rolling_samples.begin(),
                            runtime.rolling_samples.begin() + static_cast<std::ptrdiff_t>(excess)
                        );
                    }
                    accepted = true;
                } else if (valid_stream_identity(runtime, request)) {
                    runtime.preview_enabled = false;
                    runtime.streamed_accounting_valid = false;
                    runtime.pending_preview.reset();
                    runtime.abort_requested.store(true, std::memory_order_relaxed);
                }
            }
            if (accepted) {
                Frame response = response_frame(request, Operation::AudioAccepted);
                append_u64(response.payload, sequence);
                append_u64(response.payload, watermark);
                write_stream_frame(runtime, response);
            } else {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
            }
            continue;
        }

        if (request.operation == Operation::StreamDecode) {
            PayloadReader reader(request.payload);
            uint64_t revision = 0;
            uint64_t watermark = 0;
            const bool parsed = reader.read_u64(revision) && reader.read_u64(watermark)
                && reader.exhausted();
            bool accepted = false;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                if (parsed && valid_stream_identity(runtime, request)
                    && !runtime.finishing && runtime.preview_enabled
                    && revision > runtime.last_revision
                    && watermark == runtime.total_samples) {
                    const uint64_t rolling_start = runtime.total_samples
                        - static_cast<uint64_t>(runtime.rolling_samples.size());
                    const uint64_t evidence_start = std::max(
                        runtime.last_decode_watermark,
                        rolling_start
                    );
                    const size_t evidence_offset = static_cast<size_t>(
                        evidence_start - rolling_start
                    );
                    std::vector<int16_t> evidence_samples(
                        runtime.rolling_samples.begin()
                            + static_cast<std::ptrdiff_t>(evidence_offset),
                        runtime.rolling_samples.end()
                    );
                    runtime.last_revision = revision;
                    runtime.last_decode_watermark = watermark;
                    runtime.pending_preview = PreviewRequest{
                        request,
                        revision,
                        watermark,
                        runtime.preview_configuration,
                        runtime.rolling_samples,
                        std::move(evidence_samples),
                    };
                    runtime.condition.notify_one();
                    accepted = true;
                }
            }
            if (!accepted) {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
            }
            continue;
        }

        if (request.operation == Operation::StreamFinish) {
            PayloadReader reader(request.payload);
            FinalRequest final_request;
            final_request.frame = request;
            const bool parsed = reader.read_u64(final_request.expected_samples)
                && reader.read_u64(final_request.expected_hash)
                && reader.read_string(final_request.configuration.audio_path)
                && parse_stream_configuration(reader, final_request.configuration)
                && reader.exhausted()
                && !final_request.configuration.audio_path.empty()
                && final_request.configuration.vad_identity == identity.vad;
            bool accepted = false;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                if (parsed && valid_stream_identity(runtime, request)
                    && !runtime.finishing) {
                    final_request.streamed_samples = runtime.total_samples;
                    final_request.streamed_hash = runtime.audio_hash;
                    final_request.streamed_accounting_valid = runtime.streamed_accounting_valid;
                    runtime.finishing = true;
                    runtime.pending_preview.reset();
                    runtime.pending_final = std::move(final_request);
                    runtime.abort_requested.store(true, std::memory_order_relaxed);
                    runtime.condition.notify_one();
                    accepted = true;
                }
            }
            if (!accepted) {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
            }
            continue;
        }

        if (request.operation == Operation::StreamCancel) {
            const bool parsed = request.payload.empty();
            bool accepted = false;
            {
                std::lock_guard<std::mutex> lock(runtime.mutex);
                if (parsed && valid_stream_identity(runtime, request)) {
                    runtime.active = false;
                    runtime.finishing = false;
                    runtime.pending_preview.reset();
                    runtime.pending_final.reset();
                    runtime.rolling_samples.clear();
                    runtime.abort_requested.store(true, std::memory_order_relaxed);
                    accepted = true;
                }
            }
            if (accepted) {
                write_stream_frame(runtime, response_frame(request, Operation::Cancelled));
            } else {
                write_stream_error(runtime, request, ErrorCategory::Protocol);
            }
            continue;
        }

        write_stream_error(runtime, request, ErrorCategory::Protocol);
    }

    {
        std::lock_guard<std::mutex> lock(runtime.mutex);
        runtime.shutdown = true;
        runtime.active = false;
        runtime.pending_preview.reset();
        runtime.pending_final.reset();
        runtime.pending_one_shot.reset();
        runtime.abort_requested.store(true, std::memory_order_relaxed);
        runtime.condition.notify_one();
    }
    worker.join();
    if (shutdown_request.has_value()
        && !write_stream_frame(runtime, response_frame(*shutdown_request, Operation::Stopped))) {
        exit_code = 67;
    }
    free_asr_context(context);
    return exit_code;
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

uint16_t requested_protocol_version(int argc, char ** argv) {
    if (argc != 3 || std::strcmp(argv[1], "--protocol-version") != 0) {
        return 0;
    }
    if (std::strcmp(argv[2], "1") == 0) {
        return kVersion1;
    }
    if (std::strcmp(argv[2], "2") == 0) {
        return kVersion2;
    }
    return 0;
}

} // namespace

int main(int argc, char ** argv) {
    const uint16_t protocol_version = requested_protocol_version(argc, argv);
    if (protocol_version == 0) {
        return 64;
    }

    g_observed_backend.store(ObservedBackend::Unknown, std::memory_order_relaxed);
    whisper_log_set(observe_backend_log, nullptr);
    start_parent_monitor();

    Frame load_request;
    if (!read_frame(load_request, protocol_version) || load_request.operation != Operation::Load) {
        return 65;
    }
    PayloadReader load_reader(load_request.payload);
    std::string model_path;
    RuntimeIdentity identity;
    const bool load_parsed = load_reader.read_string(model_path)
        && (protocol_version == kVersion1
            || (load_reader.read_string(identity.runtime)
                && load_reader.read_string(identity.model)
                && load_reader.read_string(identity.vad)))
        && load_reader.exhausted()
        && !model_path.empty()
        && (protocol_version == kVersion1
            || (is_opaque_identity(identity.runtime)
                && is_opaque_identity(identity.model)
                && is_opaque_identity(identity.vad, true)));
    if (!load_parsed) {
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
    record_asr_context_constructed();

    if (const char * attestation = std::getenv("STENO_RUNTIME_BACKEND_ATTESTATION");
        attestation != nullptr && std::strcmp(attestation, "1") == 0) {
        whisper_state * backend_probe = whisper_init_state(context);
        if (backend_probe == nullptr) {
            write_error(load_request, ErrorCategory::ModelLoad);
            free_asr_context(context);
            return 66;
        }
        whisper_free_state(backend_probe);
        const ObservedBackend backend = g_observed_backend.load(std::memory_order_relaxed);
        const char * line = backend == ObservedBackend::Metal
            ? "STENO_BACKEND=metal\n"
            : backend == ObservedBackend::CPU
                ? "STENO_BACKEND=cpu\n"
                : "STENO_BACKEND=unknown\n";
        if (!write_exact(STDERR_FILENO, line, std::strlen(line))) {
            free_asr_context(context);
            return 67;
        }
    }

    Frame ready = response_frame(load_request, Operation::Ready);
    if (protocol_version == kVersion2) {
        append_identity_payload(ready.payload, identity);
    }
    if (!write_frame(ready)) {
        free_asr_context(context);
        return 67;
    }

    return protocol_version == kVersion1
        ? run_version_1(context)
        : run_version_2(context, load_request, identity);
}
