/* Host fixture shim: production loader.c is compiled with -D__ANDROID__ on
   macOS, so __APPLE__ is still defined in the same translation unit. The
   Apple-only branch of s2a_loader_session_reset() clears the desktop module
   window cursor, but that cursor is declared only in the non-Android branch.
   Provide inert fixture-owned definitions so this hybrid build compiles; the
   Android loader path never reads them, and a real Android build has neither
   the Apple branch nor these definitions. */
#include <stdint.h>
static uint64_t g_modcur;
static uint64_t g_slot_at;
