#ifndef WHISPER_SHIM_H
#define WHISPER_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

// Opaque forward declaration so Swift does not need the full whisper.h.
struct whisper_context;

// Runs whisper_full() with sensible streaming-friendly defaults.
// Builds the whisper_full_params struct (which must be passed by value) on the
// C side, avoiding the Swift/C ABI mismatch of passing large structs by value.
//
// Returns 0 on success, non-zero on failure.
int whisper_shim_full(struct whisper_context *ctx,
                      const float *samples,
                      int n_samples,
                      int n_threads);

#ifdef __cplusplus
}
#endif

#endif /* WHISPER_SHIM_H */
