#ifndef MUESLI_LOCALVQE_BRIDGE_H
#define MUESLI_LOCALVQE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MuesliLocalVQEContext MuesliLocalVQEContext;

MuesliLocalVQEContext *muesli_localvqe_create(
    const char *model_path,
    const char *library_path,
    int threads,
    char *error_buffer,
    int error_buffer_length
);

void muesli_localvqe_destroy(MuesliLocalVQEContext *context);
void muesli_localvqe_reset(MuesliLocalVQEContext *context);

int muesli_localvqe_process_frame_f32(
    MuesliLocalVQEContext *context,
    const float *mic,
    const float *reference,
    int hop_samples,
    float *output
);

int muesli_localvqe_sample_rate(MuesliLocalVQEContext *context);
int muesli_localvqe_hop_length(MuesliLocalVQEContext *context);
const char *muesli_localvqe_last_error(MuesliLocalVQEContext *context);

#ifdef __cplusplus
}
#endif

#endif
