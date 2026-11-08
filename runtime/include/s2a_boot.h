// Initial UIKit activation only. Later game sessions use s2a_session.h.
#pragma once

typedef void (*s2a_boot_entry)(void);
// Queue the real host continuation when prewarming or waiting for resources.
// Returns 1 when deferred, 0 for immediate boot, -1 for a conflicting entry.
// Registering the same entry again never makes a claimed entry runnable again.
int s2a_host_boot_defer(s2a_boot_entry entry, int needs_import_ui);
int s2a_host_boot_deferred(void);
int s2a_host_boot_pending(void);
// Scene activation claims the continuation exactly once, before starting its
// host pthread. The returned entry remains owned by the executable.
s2a_boot_entry s2a_host_boot_take(void);
