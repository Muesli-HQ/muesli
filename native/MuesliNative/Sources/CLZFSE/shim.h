// Portable LZFSE shim for SwiftPM `systemLibrary` targets.
// Resolves <lzfse.h> from the include search path supplied by the build
// environment (vcpkg), keeping the module map machine-independent.
#include <lzfse.h>
