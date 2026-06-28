#ifndef WHISPER_WRAPPER_H
#define WHISPER_WRAPPER_H

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    int64_t start_ms;
    int64_t end_ms;
    char* text;
    float confidence;
} WhisperSegmentResult;

typedef void* WhisperContext;

// Whisper context parameters
typedef struct {
    bool use_gpu;
    int gpu_device;
    // ... other fields (we only care about use_gpu for now)
} whisper_context_params;

// C function declarations
WhisperContext whisper_init_from_file(const char* path_model);
WhisperContext whisper_init_from_file_with_params(const char* path_model, whisper_context_params params);
whisper_context_params whisper_context_default_params(void);
void whisper_free(WhisperContext ctx);
int whisper_full(WhisperContext ctx, const float* samples, int n_samples, int sample_rate);
int whisper_full_get_segment_count(WhisperContext ctx);
const char* whisper_full_get_segment_text(WhisperContext ctx, int i_segment);
int64_t whisper_full_get_segment_t0(WhisperContext ctx, int i_segment);
int64_t whisper_full_get_segment_t1(WhisperContext ctx, int i_segment);
float whisper_full_get_segment_conf(WhisperContext ctx, int i_segment);

#endif
