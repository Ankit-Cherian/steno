// Compile the actual vendor translation unit so allocation failures reach its
// real cleanup branches. Fault injection exists only in this test executable.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

namespace allocation_probe {
bool armed = false;
bool fail_array = false;
size_t fail_size = 0;
size_t track_size = 0;
int failures = 0;
int allocations = 0;
int releases = 0;
void * tracked = nullptr;

void start(bool array, size_t size, size_t owned_size) {
    armed = true;
    fail_array = array;
    fail_size = size;
    track_size = owned_size;
    failures = allocations = releases = 0;
    tracked = nullptr;
}

void * allocate(size_t size, bool array, bool throwing) {
    if (armed && array == fail_array && size == fail_size && failures == 0) {
        ++failures;
        if (throwing) {
            throw std::bad_alloc();
        }
        return nullptr;
    }
    void * pointer = std::malloc(size == 0 ? 1 : size);
    if (!pointer && throwing) {
        throw std::bad_alloc();
    }
    if (armed && !array && size == track_size && pointer) {
        ++allocations;
        tracked = pointer;
    }
    return pointer;
}

void release(void * pointer) noexcept {
    if (armed && pointer && pointer == tracked) {
        ++releases;
    }
    std::free(pointer);
}
}

void * operator new(size_t size) { return allocation_probe::allocate(size, false, true); }
void * operator new[](size_t size) { return allocation_probe::allocate(size, true, true); }
void * operator new(size_t size, const std::nothrow_t &) noexcept {
    return allocation_probe::allocate(size, false, false);
}
void * operator new[](size_t size, const std::nothrow_t &) noexcept {
    return allocation_probe::allocate(size, true, false);
}
void operator delete(void * pointer) noexcept { allocation_probe::release(pointer); }
void operator delete[](void * pointer) noexcept { allocation_probe::release(pointer); }
void operator delete(void * pointer, size_t) noexcept { allocation_probe::release(pointer); }
void operator delete[](void * pointer, size_t) noexcept { allocation_probe::release(pointer); }
void operator delete(void * pointer, const std::nothrow_t &) noexcept { allocation_probe::release(pointer); }
void operator delete[](void * pointer, const std::nothrow_t &) noexcept { allocation_probe::release(pointer); }

#include STENO_VENDOR_IMPLEMENTATION

static int failed_checks = 0;

static void check(bool condition, const char * label) {
    std::printf("%s: %s\n", condition ? "PASS" : "FAIL", label);
    if (!condition) {
        ++failed_checks;
    }
}

static void finish_failure(bool threw, bool returned_null, int owned_count, const char * label) {
    const bool passed = !threw && returned_null && allocation_probe::failures == 1
        && allocation_probe::allocations == owned_count
        && allocation_probe::releases == owned_count;
    allocation_probe::armed = false;
    if (!passed) {
        std::printf("DETAIL: threw=%d null=%d injected=%d owned=%d released=%d\n",
                    threw, returned_null, allocation_probe::failures,
                    allocation_probe::allocations, allocation_probe::releases);
    }
    check(passed, label);
}

#if STENO_ALLOCATION_TEST_CPU
int main() {
    // Initialize process-wide registries before enabling allocation injection.
    auto * control = ggml_backend_cpu_init();
    if (!control) {
        check(false, "CPU successful initialization");
        return 1;
    }
    check(ggml_backend_is_cpu(control), "CPU successful initialization");
    ggml_backend_cpu_free(control);

    for (bool fail_context : {true, false}) {
        allocation_probe::start(false,
            fail_context ? sizeof(ggml_backend_cpu_context) : sizeof(ggml_backend),
            fail_context ? 0 : sizeof(ggml_backend_cpu_context));
        ggml_backend_t result = nullptr;
        bool threw = false;
        try {
            result = ggml_backend_cpu_init();
        } catch (const std::bad_alloc &) {
            threw = true;
        }
        finish_failure(threw, result == nullptr, fail_context ? 0 : 1,
            fail_context ? "CPU context allocation failure returns null"
                         : "CPU backend allocation failure releases context");
        if (result) {
            ggml_backend_cpu_free(result);
        }
    }

    auto * backend = ggml_backend_cpu_init();
    ggml_backend_cpu_set_n_threads(backend, 1);
    ggml_init_params parameters = {1024 * 1024, nullptr, true};
    auto * context = ggml_init(parameters);
    auto * graph = ggml_new_graph(context);
    auto * left = ggml_new_tensor_2d(context, GGML_TYPE_F16, 32, 32);
    auto * right = ggml_new_tensor_2d(context, GGML_TYPE_F32, 32, 32);
    ggml_build_forward_expand(graph, ggml_mul_mat(context, left, right));
    const size_t workspace_size = ggml_graph_plan(graph, 1, nullptr).work_size;
    if (workspace_size == 0) {
        check(false, "plan fixture requires workspace");
        ggml_free(context);
        ggml_backend_cpu_free(backend);
        return 1;
    }
    auto * plan = ggml_backend_cpu_graph_plan_create(backend, graph);
    check(plan != nullptr, "plan successful allocation");
    if (plan) {
        ggml_backend_cpu_graph_plan_free(backend, plan);
    }
    allocation_probe::start(true, workspace_size, sizeof(ggml_backend_plan_cpu));
    bool threw = false;
    plan = nullptr;
    try {
        plan = ggml_backend_cpu_graph_plan_create(backend, graph);
    } catch (const std::bad_alloc &) {
        threw = true;
    }
    finish_failure(threw, plan == nullptr, 1, "plan workspace failure releases plan");
    if (plan) {
        ggml_backend_cpu_graph_plan_free(backend, plan);
    }
    ggml_free(context);
    ggml_backend_cpu_free(backend);
    return failed_checks == 0 ? 0 : 1;
}
#else
int main() {
    whisper_vad_context context{};
    context.n_window = 512;
    // 320 ms of speech, then enough silence to close the segment.
    context.probs.assign(16, 0.0f);
    for (int index = 0; index < 10; ++index) {
        context.probs[index] = 0.9f;
    }
    auto parameters = whisper_vad_default_params();
    parameters.speech_pad_ms = 0;
    auto * segments = whisper_vad_segments_from_probs(&context, parameters);
    check(segments && segments->data.size() == 1
          && segments->data[0].start == 0 && segments->data[0].end == 32,
          "VAD successful allocation preserves synthetic segment boundaries");
    whisper_vad_free_segments(segments);

    allocation_probe::start(false, sizeof(whisper_vad_segments), sizeof(whisper_vad_segment));
    bool threw = false;
    segments = nullptr;
    try {
        segments = whisper_vad_segments_from_probs(&context, parameters);
    } catch (const std::bad_alloc &) {
        threw = true;
    }
    finish_failure(threw, segments == nullptr, 1, "VAD output allocation failure releases prepared segments");
    whisper_vad_free_segments(segments);
    return failed_checks == 0 ? 0 : 1;
}
#endif
