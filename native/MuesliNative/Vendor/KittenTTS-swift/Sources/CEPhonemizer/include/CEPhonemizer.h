// Copyright 2024 - Apache 2.0 License
// C bridge for EPhonemizer — callable from Swift via SPM C interop.

#ifndef CEPHONEMIZER_H
#define CEPHONEMIZER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a phonemizer instance.
typedef void* PhonemizerHandle;

/// Create a new phonemizer instance.
/// @param rules_path  Path to the rules file.
/// @param list_path   Path to the dictionary file.
/// @param dialect     Dialect string, e.g. "en-us". Pass NULL for default.
/// @return Handle, or NULL on failure.
PhonemizerHandle phonemizer_create(const char* rules_path,
                                    const char* list_path,
                                    const char* dialect);

/// Destroy a phonemizer instance.
void phonemizer_destroy(PhonemizerHandle handle);

/// Phonemize a single text string.
/// @return Newly allocated IPA string. Caller must free with phonemizer_free_string().
///         Returns NULL on failure.
char* phonemizer_phonemize(PhonemizerHandle handle, const char* text);

/// Free a string returned by phonemizer_phonemize().
void phonemizer_free_string(char* str);

/// Get error message from a failed create.
const char* phonemizer_get_error(PhonemizerHandle handle);

#ifdef __cplusplus
}
#endif

#endif // CEPHONEMIZER_H
