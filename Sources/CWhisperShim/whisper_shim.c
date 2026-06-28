#include "whisper_shim.h"
#include <whisper.h>

int whisper_shim_full(struct whisper_context *ctx,
                      const float *samples,
                      int n_samples,
                      int n_threads) {
    if (ctx == NULL || samples == NULL || n_samples <= 0) {
        return -1;
    }

    struct whisper_full_params params =
        whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    params.print_progress   = false;
    params.print_realtime   = false;
    params.print_special    = false;
    params.print_timestamps = false;
    params.single_segment   = false;
    params.no_context       = true;
    params.translate        = false;
    params.language         = "en";
    params.n_threads        = n_threads > 0 ? n_threads : 4;

    return whisper_full(ctx, params, samples, n_samples);
}
