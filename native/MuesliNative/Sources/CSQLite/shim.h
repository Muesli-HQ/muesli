// Portable SQLite shim for SwiftPM `systemLibrary` targets.
// Resolves <sqlite3.h> from the include search path supplied by the build
// environment (vcpkg), so no machine-specific path is baked into the module map.
#include <sqlite3.h>
