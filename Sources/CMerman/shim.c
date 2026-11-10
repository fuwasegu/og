// CMerman only declares the merman native C ABI (headers vendored from the merman SDK, MIT/Apache-2.0).
// og loads libmerman_ffi.dylib at run time with dlopen, so nothing links against it here.
#include "merman.h"
