#include "LocalVQEBridge.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uintptr_t localvqe_ctx_t;
typedef uintptr_t localvqe_options_t;

typedef localvqe_options_t (*localvqe_options_new_fn)(void);
typedef void (*localvqe_options_free_fn)(localvqe_options_t);
typedef int (*localvqe_options_set_model_path_fn)(localvqe_options_t, const char *);
typedef int (*localvqe_options_set_backend_fn)(localvqe_options_t, const char *);
typedef int (*localvqe_options_set_threads_fn)(localvqe_options_t, int);
typedef localvqe_ctx_t (*localvqe_new_with_options_fn)(localvqe_options_t);
typedef void (*localvqe_free_fn)(localvqe_ctx_t);
typedef void (*localvqe_reset_fn)(localvqe_ctx_t);
typedef int (*localvqe_process_frame_f32_fn)(localvqe_ctx_t, const float *, const float *, int, float *);
typedef int (*localvqe_sample_rate_fn)(localvqe_ctx_t);
typedef int (*localvqe_hop_length_fn)(localvqe_ctx_t);
typedef const char *(*localvqe_last_error_fn)(localvqe_ctx_t);

struct MuesliLocalVQEContext {
    void *library;
    localvqe_ctx_t localvqe;
    localvqe_free_fn free_context;
    localvqe_reset_fn reset;
    localvqe_process_frame_f32_fn process_frame_f32;
    localvqe_sample_rate_fn sample_rate;
    localvqe_hop_length_fn hop_length;
    localvqe_last_error_fn last_error;
    char error[1024];
};

static void set_error(char *buffer, int length, const char *message) {
    if (buffer != NULL && length > 0) {
        snprintf(buffer, (size_t)length, "%s", message != NULL ? message : "unknown LocalVQE error");
    }
}

static void context_error(MuesliLocalVQEContext *context, const char *message) {
    if (context != NULL) {
        snprintf(context->error, sizeof(context->error), "%s", message != NULL ? message : "unknown LocalVQE error");
    }
}

static void *require_symbol(void *library, const char *name, char *error_buffer, int error_buffer_length) {
    dlerror();
    void *symbol = dlsym(library, name);
    const char *error = dlerror();
    if (error != NULL || symbol == NULL) {
        char message[512];
        snprintf(message, sizeof(message), "LocalVQE symbol not found: %s (%s)", name, error != NULL ? error : "null symbol");
        set_error(error_buffer, error_buffer_length, message);
        return NULL;
    }
    return symbol;
}

MuesliLocalVQEContext *muesli_localvqe_create(
    const char *model_path,
    const char *library_path,
    int threads,
    char *error_buffer,
    int error_buffer_length
) {
    if (model_path == NULL || model_path[0] == '\0') {
        set_error(error_buffer, error_buffer_length, "LocalVQE model path is empty");
        return NULL;
    }

    const char *path = (library_path != NULL && library_path[0] != '\0')
        ? library_path
        : "liblocalvqe.dylib";
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        char message[1024];
        snprintf(message, sizeof(message), "Could not load LocalVQE library at %s: %s", path, dlerror());
        set_error(error_buffer, error_buffer_length, message);
        return NULL;
    }

    localvqe_options_new_fn options_new = (localvqe_options_new_fn)require_symbol(library, "localvqe_options_new", error_buffer, error_buffer_length);
    localvqe_options_free_fn options_free = (localvqe_options_free_fn)require_symbol(library, "localvqe_options_free", error_buffer, error_buffer_length);
    localvqe_options_set_model_path_fn set_model_path = (localvqe_options_set_model_path_fn)require_symbol(library, "localvqe_options_set_model_path", error_buffer, error_buffer_length);
    localvqe_options_set_backend_fn set_backend = (localvqe_options_set_backend_fn)require_symbol(library, "localvqe_options_set_backend", error_buffer, error_buffer_length);
    localvqe_options_set_threads_fn set_threads = (localvqe_options_set_threads_fn)require_symbol(library, "localvqe_options_set_threads", error_buffer, error_buffer_length);
    localvqe_new_with_options_fn new_with_options = (localvqe_new_with_options_fn)require_symbol(library, "localvqe_new_with_options", error_buffer, error_buffer_length);
    localvqe_free_fn free_context = (localvqe_free_fn)require_symbol(library, "localvqe_free", error_buffer, error_buffer_length);
    localvqe_reset_fn reset = (localvqe_reset_fn)require_symbol(library, "localvqe_reset", error_buffer, error_buffer_length);
    localvqe_process_frame_f32_fn process_frame = (localvqe_process_frame_f32_fn)require_symbol(library, "localvqe_process_frame_f32", error_buffer, error_buffer_length);
    localvqe_sample_rate_fn sample_rate = (localvqe_sample_rate_fn)require_symbol(library, "localvqe_sample_rate", error_buffer, error_buffer_length);
    localvqe_hop_length_fn hop_length = (localvqe_hop_length_fn)require_symbol(library, "localvqe_hop_length", error_buffer, error_buffer_length);
    localvqe_last_error_fn last_error = (localvqe_last_error_fn)require_symbol(library, "localvqe_last_error", error_buffer, error_buffer_length);

    if (options_new == NULL || options_free == NULL || set_model_path == NULL ||
        set_backend == NULL || set_threads == NULL || new_with_options == NULL ||
        free_context == NULL || reset == NULL || process_frame == NULL ||
        sample_rate == NULL || hop_length == NULL || last_error == NULL) {
        dlclose(library);
        return NULL;
    }

    localvqe_options_t options = options_new();
    if (options == 0) {
        set_error(error_buffer, error_buffer_length, "Could not allocate LocalVQE options");
        dlclose(library);
        return NULL;
    }

    int status = set_model_path(options, model_path);
    if (status == 0) {
        status = set_backend(options, "CPU");
    }
    if (status == 0 && threads > 0) {
        status = set_threads(options, threads);
    }
    if (status != 0) {
        char message[256];
        snprintf(message, sizeof(message), "Could not configure LocalVQE options (status %d)", status);
        set_error(error_buffer, error_buffer_length, message);
        options_free(options);
        dlclose(library);
        return NULL;
    }

    localvqe_ctx_t localvqe = new_with_options(options);
    options_free(options);
    if (localvqe == 0) {
        set_error(error_buffer, error_buffer_length, "LocalVQE failed to load model");
        dlclose(library);
        return NULL;
    }

    MuesliLocalVQEContext *context = (MuesliLocalVQEContext *)calloc(1, sizeof(MuesliLocalVQEContext));
    if (context == NULL) {
        free_context(localvqe);
        dlclose(library);
        set_error(error_buffer, error_buffer_length, "Could not allocate Muesli LocalVQE context");
        return NULL;
    }

    context->library = library;
    context->localvqe = localvqe;
    context->free_context = free_context;
    context->reset = reset;
    context->process_frame_f32 = process_frame;
    context->sample_rate = sample_rate;
    context->hop_length = hop_length;
    context->last_error = last_error;
    context->error[0] = '\0';
    return context;
}

void muesli_localvqe_destroy(MuesliLocalVQEContext *context) {
    if (context == NULL) { return; }
    if (context->localvqe != 0 && context->free_context != NULL) {
        context->free_context(context->localvqe);
    }
    if (context->library != NULL) {
        dlclose(context->library);
    }
    free(context);
}

void muesli_localvqe_reset(MuesliLocalVQEContext *context) {
    if (context == NULL || context->reset == NULL || context->localvqe == 0) { return; }
    context->reset(context->localvqe);
    context->error[0] = '\0';
}

int muesli_localvqe_process_frame_f32(
    MuesliLocalVQEContext *context,
    const float *mic,
    const float *reference,
    int hop_samples,
    float *output
) {
    if (context == NULL || context->process_frame_f32 == NULL || context->localvqe == 0) {
        return -100;
    }
    int hop = muesli_localvqe_hop_length(context);
    if (hop_samples != hop) {
        context_error(context, "LocalVQE frame size must match hop length");
        return -101;
    }
    if (mic == NULL || reference == NULL || output == NULL) {
        context_error(context, "LocalVQE frame pointers must be non-null");
        return -102;
    }
    int result = context->process_frame_f32(context->localvqe, mic, reference, hop_samples, output);
    if (result == 0) {
        context->error[0] = '\0';
    }
    return result;
}

int muesli_localvqe_sample_rate(MuesliLocalVQEContext *context) {
    if (context == NULL || context->sample_rate == NULL || context->localvqe == 0) { return 0; }
    return context->sample_rate(context->localvqe);
}

int muesli_localvqe_hop_length(MuesliLocalVQEContext *context) {
    if (context == NULL || context->hop_length == NULL || context->localvqe == 0) { return 0; }
    return context->hop_length(context->localvqe);
}

const char *muesli_localvqe_last_error(MuesliLocalVQEContext *context) {
    if (context == NULL) { return "LocalVQE context is null"; }
    if (context->error[0] != '\0') { return context->error; }
    if (context->last_error == NULL || context->localvqe == 0) { return ""; }
    const char *error = context->last_error(context->localvqe);
    return error != NULL ? error : "";
}
