// Exercises the pinned scheduler helper and CPU or Metal backend without a model.
#include STENO_VENDOR_IMPLEMENTATION
#include <cmath>
#include <stdexcept>

struct cancellation_probe {
    int calls = 0;
    int cancel_at = 0;
};

static bool cancel_probe(void * data) {
    auto & probe = *static_cast<cancellation_probe *>(data);
    return ++probe.calls >= probe.cancel_at;
}

static bool require_check(bool condition, const char * message) {
    fprintf(stderr, "%s: %s\n", condition ? "PASS" : "FAIL", message);
    return condition;
}

static bool throw_during_compute(ggml_tensor *, bool, void *) {
    throw std::runtime_error("injected scheduler computation failure");
}

int main(int argc, char ** argv) {
    const bool metal = argc == 2 && std::string(argv[1]) == "metal";
    ggml_backend_t backend = ggml_backend_init_by_type(
        metal ? GGML_BACKEND_DEVICE_TYPE_GPU : GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (!backend) return 2;
    ggml_backend_t cpu_fallback = metal ? ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr) : nullptr;
    if (metal && !cpu_fallback) return 2;
    ggml_backend_t backends[] = {backend, cpu_fallback};
    ggml_backend_sched_t sched = ggml_backend_sched_new(backends, nullptr, metal ? 2 : 1, 128, false, true);
    ggml_context * ctx = nullptr;
    ggml_tensor * input = nullptr;
    ggml_tensor * output = nullptr;
    ggml_cgraph * graph = nullptr;
    auto new_graph = [&]() {
        // Scheduler reset invalidates tensor allocations; rebuild their metadata.
        if (ctx) ggml_free(ctx);
        ggml_init_params params = { 1024 * 1024, nullptr, true };
        ctx = ggml_init(params);
        if (!ctx) return false;
        input = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 256);
        ggml_set_input(input);
        output = input;
        for (int i = 0; i < 16; ++i) output = ggml_scale(ctx, output, 1.01f);
        ggml_set_output(output);
        graph = ggml_new_graph_custom(ctx, 128, false);
        ggml_build_forward_expand(graph, output);
        return true;
    };
    if (!sched || !new_graph()) return 2;
    bool passed = true;
    auto reg = ggml_backend_dev_backend_reg(ggml_backend_get_device(backend));
    passed &= require_check(ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_abort_callback") != nullptr,
                            "backend registry exposes its cancellation setter");
    auto prepare = [&]() {
        if (!new_graph()) return false;
        if (metal) {
            ggml_backend_sched_set_tensor_backend(sched, input, backend);
            for (int i = 0; i < ggml_graph_n_nodes(graph); ++i) {
                ggml_backend_sched_set_tensor_backend(sched, ggml_graph_node(graph, i), backend);
            }
        }
        if (!ggml_backend_sched_alloc_graph(sched, graph)) return false;
        float data[256];
        std::fill_n(data, 256, 1.0f);
        ggml_backend_tensor_set(input, data, 0, sizeof(data));
        return true;
    };
    cancellation_probe early {0, 1};
    passed &= require_check(!ggml_graph_compute_helper(sched, graph, 2, true, cancel_probe, &early)
                            && early.calls == 1, "pre-cancel stops before graph computation");
    if (!prepare()) return 2;
    cancellation_probe during {0, 2};
    if (!metal) {
        passed &= require_check(!ggml_graph_compute_helper(sched, graph, 2, true, cancel_probe, &during)
                                && during.calls == 2, "CPU observes cancellation during graph computation");
    } else {
        // The helper rejects an already-cancelled request before Metal submission.
        during.cancel_at = 1;
        passed &= require_check(!ggml_graph_compute_helper(sched, graph, 2, true, cancel_probe, &during)
                                && during.calls == 1, "helper rejects a pre-cancelled Metal graph");
    }
    const int cancelled_calls = during.calls;
    if (!prepare()) return 2;
    // Bypass the helper so it cannot hide a callback left on the reused backend.
    passed &= require_check(ggml_backend_sched_graph_compute(sched, graph) == GGML_STATUS_SUCCESS
                            && during.calls == cancelled_calls,
                            metal ? "Metal graph remains usable after pre-cancellation" : "cancelled graph clears the backend callback before reuse");
    ggml_backend_sched_reset(sched);
    if (!prepare()) return 2;
    cancellation_probe throwing {0, 1000};
    ggml_backend_sched_set_eval_callback(sched, throw_during_compute, nullptr);
    bool caught = false;
    try {
        ggml_graph_compute_helper(sched, graph, 2, true, cancel_probe, &throwing);
    } catch (const std::runtime_error &) {
        caught = true;
    }
    ggml_backend_sched_set_eval_callback(sched, nullptr, nullptr);
    const int exception_calls = throwing.calls;
    passed &= require_check(caught, "injected exception traverses the real scheduler helper");
    passed &= require_check(ggml_backend_sched_graph_compute(sched, graph) == GGML_STATUS_SUCCESS
                            && throwing.calls == exception_calls,
                            metal ? "Metal graph remains usable after a scheduler exception" : "exception clears the backend callback before healthy reuse");
    ggml_backend_sched_reset(sched);
    if (!prepare()) return 2;
    if (metal) {
        passed &= require_check(ggml_backend_sched_get_tensor_backend(sched, output) == backend,
                                "healthy graph output is assigned to the Metal backend");
    }
    cancellation_probe healthy {0, 1000};
    passed &= require_check(ggml_graph_compute_helper(sched, graph, 2, false, cancel_probe, &healthy)
                            && healthy.calls >= (metal ? 1 : 2), metal ? "healthy Metal request completes" : "healthy request completes with callback installed");
    float result = 0;
    ggml_backend_tensor_get(output, &result, 0, sizeof(result));
    fprintf(stderr, "Graph result: %.8f; expected: %.8f\n", result, std::pow(1.01f, 16));
    passed &= require_check(std::abs(result - std::pow(1.01f, 16)) < 0.0001f,
                            "healthy reused graph preserves numerical output");
    const int healthy_calls = healthy.calls;
    passed &= require_check(ggml_backend_sched_graph_compute(sched, graph) == GGML_STATUS_SUCCESS
                            && healthy.calls == healthy_calls,
                            metal ? "successful Metal graph can be reused without scheduler reset" : "successful graph clears callback even without scheduler reset");
    ggml_backend_sched_free(sched);
    ggml_free(ctx);
    ggml_backend_free(backend);
    if (cpu_fallback) ggml_backend_free(cpu_fallback);
    return passed ? 0 : 1;
}
