// Copyright 2024 - Apache 2.0 License
// C bridge for the phonemizer engine

#include "phonemizer.h"
#include <cstring>
#include <cstdlib>
#include <new>

extern "C" {

// Opaque handle type
typedef void* PhonemizerHandle;

// Create a new phonemizer instance
// Returns NULL on failure
PhonemizerHandle phonemizer_create(const char* rules_path,
                                    const char* list_path,
                                    const char* dialect) {
    try {
        std::string d = dialect ? std::string(dialect) : "en-us";
        auto* p = new IPAPhonemizer(rules_path, list_path, d);
        if (!p->isLoaded()) {
            delete p;
            return nullptr;
        }
        return (PhonemizerHandle)p;
    } catch (...) {
        return nullptr;
    }
}

// Destroy a phonemizer instance
void phonemizer_destroy(PhonemizerHandle handle) {
    if (handle) {
        delete (IPAPhonemizer*)handle;
    }
}

// Phonemize a single text string
// Returns a newly allocated string (caller must free with phonemizer_free_string)
// Returns NULL on failure
char* phonemizer_phonemize(PhonemizerHandle handle, const char* text) {
    if (!handle || !text) return nullptr;
    try {
        auto* p = (IPAPhonemizer*)handle;
        std::string result = p->phonemizeText(text);
        char* out = (char*)malloc(result.size() + 1);
        if (!out) return nullptr;
        memcpy(out, result.c_str(), result.size() + 1);
        return out;
    } catch (...) {
        return nullptr;
    }
}

// Free a string returned by phonemizer_phonemize
void phonemizer_free_string(char* str) {
    free(str);
}

// Get error message from a failed create
const char* phonemizer_get_error(PhonemizerHandle handle) {
    if (!handle) return "null handle";
    return ((IPAPhonemizer*)handle)->getError().c_str();
}

} // extern "C"
