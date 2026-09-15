# Native runtime corrections

`whisper-security.patch` applies to upstream whisper.cpp revision `764482c3175d9c3bc6089c1ec84df7d1b9537d83`. The runtime builder verifies the original checkout, copies its tracked source into an isolated build directory, and applies this patch there. It never edits the upstream checkout. The generated source manifest records the full revision, patch SHA-256 and every staged file hash; reuse reconstructs and checks that content before building.

The patch addresses 61 results from the C++ scan in [PR #16](https://github.com/Ankit-Cherian/steno/pull/16):

| Source | Results | Correction |
| --- | ---: | --- |
| `examples/common-ggml.cpp` | 2 | Calculate element byte counts with the destination size type. |
| `examples/miniaudio.h` | 8 | Widen frame and stride counts before calculating byte offsets. |
| `ggml/src/ggml-backend.cpp` | 11 | Make the shared scheduler index multiplication use `size_t`. Current scheduler bounds already limit this product to 60. |
| `ggml/src/ggml-cpu/repack.cpp` | 18 | Retain 64-bit tensor dimensions and row iteration across nine packing functions. |
| `ggml/src/ggml-metal/ggml-metal-ops.cpp` | 2 | Widen dispatch and shared-memory products before multiplication. |
| `ggml/src/ggml-opt.cpp` | 1 | Calculate the loss-statistics square in double precision. |
| `src/whisper.cpp` | 15 | Widen buffer sizes and tensor-view lengths; calculate the mel remainder product in double precision. |
| `ggml/src/ggml-cpu/ggml-cpu.cpp` and `src/whisper.cpp` | 4 | Use nonthrowing allocation where existing null checks release owned memory or return failure. |

The two double-precision changes can alter rounding. The mel change is on the inference path, so changes to this patch require transcription comparisons and the benchmark gates. Operand widening does not validate arbitrary tensor dimensions or establish complete protection against malformed models. The four allocation fixes do not make all surrounding operations exception-free.

A separate CMake correction directs generated JavaScript package metadata into the build directory. This keeps the staged source unchanged after configuration and allows its hashes to be verified on reuse.

The native CI lane compiles the actual patched CPU and Whisper translation units into isolated allocation-test executables. Four injected allocation failures verify null returns and cleanup; successful controls cover CPU initialization, plan creation and synthetic VAD segment boundaries. The injection code is not linked into the shipped helper. Separate cancellation tests compile the actual scheduler helper and exercise real backend graphs, cancellation, healthy reuse and callback cleanup after an injected compute exception. The native lane runs these checks before the helper protocol suite.

The patch also connects Whisper's existing request cancellation callback to its scheduler-based graph computation. Each graph sets the callback on participating backends and uses scoped cleanup to synchronize and clear the callback and request data after success, cancellation or an exception. CPU already exposes the setter through its registry; the Metal registry now exports its existing setter under the same name. The callback is passed through the three encoder graphs and the decoder graph. Calls without a cancellation callback retain their existing behavior.

Cancellation follows each backend's supported boundaries. CPU can stop between compute nodes. Metal keeps its existing command-buffer scheduling and cancellation granularity; this patch does not promise immediate interruption of a submitted GPU graph.

When changing the upstream pin or this patch, select a fresh build directory. A CMake cache bound to different source content fails rather than being retargeted or deleted. Keep the upstream license notices, review every patch hunk against the new revision, and rerun allocation, runtime, transcription and security checks. No scanner rule or severity threshold is suppressed by this patch.
