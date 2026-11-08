"""Keep recent complete titles; evict cold reusable entries only under disk pressure.

Logical file sizes are diagnostic only, never a trigger or a freed-space estimate.
The caller holds the existing library execution lock (not a global producer lock).
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import shutil
import time

KEEP_TITLES = 3
# Same fixed headroom used by library.check_pack_space for a user's single build.
# Do not inherit the maintenance fleet's 130 GiB auto-build gate.
MIN_FREE_BYTES = 10 * 1024**3
HOT_SECONDS = 3600


def retention_policy():
    def integer(name, default, minimum):
        value = os.environ.get(name)
        if value is None:
            return default
        if not re.fullmatch(r'[0-9]+', value) or int(value) < minimum:
            raise ValueError(name + ' 必须是至少 ' + str(minimum) + ' 的整数')
        return int(value)
    return dict(keep_titles=integer('S2A_COMPILER_CACHE_KEEP_TITLES', KEEP_TITLES, 1),
                min_free_bytes=integer('S2A_COMPILER_CACHE_MIN_FREE_BYTES', MIN_FREE_BYTES, 0))


def roots(private):
    private = Path(private)
    return ((private / 'cache' / 'air', '.air'),
            (private / 'cache' / 'pso', '.bin'),
            (private / 'run' / 'gal_dl_cache', '.metallib'),
            (private / 'run/s2arm/cache/direct', 'direct'))


def _safe_root(private, path):
    """Do not traverse links, including an intermediate cache/run directory."""
    here = Path(private)
    for part in path.relative_to(here).parts:
        here /= part
        try:
            mode = here.lstat().st_mode
        except FileNotFoundError:
            return 'missing'
        if not stat.S_ISDIR(mode):
            return 'unsafe'
    return 'safe'


def _completed(root, path, suffix):
    """Recognize only existing producer layouts, not arbitrary hash-named files."""
    parts = path.relative_to(root).parts
    name = parts[-1]
    if suffix == 'direct':
        # Direct store (C# dsh_batch build Store, graphics/tools/direct/dsh/batch/Build.cs, S2Arm 11-01; direct_lib.sh gives it --cas <title>/store):
        # <title>/store/dshb/<two hex>/<64 hex>.e, one entry per file (a translation or a Metal library), named by the sha256 of its key and filed under
        # its first two hex digits. Removing one only makes it miss on the next build; <64 hex>.e.tmp<pid>.<thread> is an entry being written, not an entry.
        # <title>/store/<two hex>.pack(.bad) are shards of the former Python store (dmsh_store.py, 10-31 to 11-01): no reader is left, reclaimable the same way
        if len(parts) < 3 or not re.fullmatch(r'[0-9A-F]{16}', parts[0]) or parts[1] != 'store':
            return False
        if len(parts) == 5:
            return parts[2] == 'dshb' and bool(re.fullmatch(r'[0-9a-f]{64}\.e', name)) and parts[3] == name[:2]
        return len(parts) == 3 and bool(re.fullmatch(r'[0-9a-f]{2}\.pack(?:\.bad)?', name))
    if not re.fullmatch(r'[0-9a-f]{64}' + re.escape(suffix), name):
        return False
    key = name[:64]
    if suffix == '.bin':
        return len(parts) == 2 and parts[0] == key[:2]
    prefixes = (key[:2], ('u' if suffix == '.air' else 'b') + key[:2])
    return len(parts) == 3 and parts[0] in ('ios', 'macos') and parts[1] in prefixes


def _signature(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def trim(private, *, keep_titles=KEEP_TITLES, min_free_bytes=MIN_FREE_BYTES,
         now=None, current_gid=None, free_bytes=None):
    """Trim completed cold entries, oldest first; report observed regular-file bytes.

    Only content-addressed compiler outputs are eligible. No directory, link,
    temporary file, unknown payload or recently used entry is removed. Concurrent
    replacement/refresh noticed before unlink is protected. Do not infer Metal
    cache validity or a compilation speedup from this filesystem-only operation.
    """
    for value, minimum in ((keep_titles, 1), (min_free_bytes, 0)):
        if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
            raise ValueError('invalid compiler cache retention policy')
    if current_gid is not None and not re.fullmatch(r'[0-9A-F]{16}', current_gid):
        raise ValueError('current_gid must be an uppercase 16-digit title ID')
    private = Path(private)
    now = time.time() if now is None else now
    candidates = []
    protected_titles = set()
    free_bytes = free_bytes or (lambda: shutil.disk_usage(private).free)
    total = removed = count = skipped = unscanned = links = 0
    errors = []
    scan_errors = eviction_errors = 0
    def record(operation, error, path):
        if len(errors) < 16:
            errors.append(dict(operation=operation, errno=error.errno,
                               path=os.path.relpath(path, private)))
    for root, suffix in roots(private):
        root_incomplete = False
        def scan_error(error):
            nonlocal root_incomplete, scan_errors
            root_incomplete = True
            scan_errors += 1
            record('scan', error, error.filename or root)
        try:
            state = _safe_root(private, root)
        except OSError as error:
            scan_error(error)
            unscanned += 1
            continue
        if state != 'safe':
            unscanned += state == 'unsafe'
            continue
        direct_used = {}
        if suffix == 'direct':
            try:
                for game in root.iterdir():
                    if not re.fullmatch(r'[0-9A-F]{16}', game.name):
                        continue
                    for platform in ('store',):
                        base = game / platform
                        if _safe_root(private, base) != 'safe':
                            continue
                        if game.name == current_gid:
                            # dmsh hits do not touch mtime. Jobs records conservative
                            # whole-title use, never claiming per-entry hit recency.
                            os.utime(base, (now, now), follow_symlinks=False)
                        direct_used[(game.name, platform)] = base.lstat().st_mtime
            except OSError as error:
                scan_error(error)
        if suffix == 'direct':
            recency = {}
            for (gid, platform), used in direct_used.items():
                recency[gid] = max(recency.get(gid, used), used)
            ordered = sorted(recency, key=lambda gid: (gid != current_gid, -recency[gid], gid))
            protected_titles.update(ordered if root_incomplete else ordered[:keep_titles])
        for directory, dirs, names in os.walk(root, followlinks=False, onerror=scan_error):
            if suffix == 'direct':
                depth = len(Path(directory).relative_to(root).parts)
                if depth == 0:
                    dirs[:] = [d for d in dirs if re.fullmatch(r'[0-9A-F]{16}', d)]
                elif depth == 1:
                    dirs[:] = [d for d in dirs if d == 'store']
            safe_dirs = []
            for name in sorted(dirs):
                path = Path(directory) / name
                try:
                    if stat.S_ISLNK(path.lstat().st_mode):
                        links += 1
                    else:
                        safe_dirs.append(name)
                except OSError as error:
                    scan_error(error)
            dirs[:] = safe_dirs
            for name in sorted(names):
                if suffix == 'direct' and depth < 2:
                    continue  # only the store belongs to this budget
                path = Path(directory) / name
                try:
                    st = path.lstat()
                except OSError as error:
                    scan_error(error)
                    continue
                if not stat.S_ISREG(st.st_mode):
                    links += stat.S_ISLNK(st.st_mode)
                    continue
                total += st.st_size
                # Hash filenames are the existing AIR/PSO/DL producer contract;
                # .tmp suffixes, logs and future formats are deliberately not GC'd.
                used = st.st_mtime
                if suffix == 'direct':
                    relative = path.relative_to(root).parts
                    if len(relative) >= 2:
                        used = max(used, direct_used.get(tuple(relative[:2]), now))
                protected = suffix == 'direct' and relative[0] in protected_titles
                if not protected and _completed(root, path, suffix) and now - used >= HOT_SECONDS:
                    candidates.append((int(used * 1e9), str(path), path, st))
        unscanned += root_incomplete
    before = total
    disk_errors = 0
    def available():
        nonlocal disk_errors
        try:
            value = free_bytes()
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise OSError('invalid disk-free reading')
            return value
        except OSError as error:
            disk_errors += 1
            record('disk-free', error, private)
            return None
    free = available()
    for _, _, path, observed in sorted(candidates):
        if free is None or free >= min_free_bytes:
            break
        try:
            current = path.lstat()
            if _signature(current) != _signature(observed):
                skipped += 1
                continue
            path.unlink()
        except FileNotFoundError:
            skipped += 1
            continue
        except OSError as error:
            eviction_errors += 1
            record('evict', error, path)
            continue
        removed += observed.st_size
        total -= observed.st_size
        count += 1
        free = available()  # APFS clones/sparse files: never add logical removed bytes.
    return dict(keepTitles=keep_titles, protectedTitles=sorted(protected_titles),
                minFreeBytes=min_free_bytes, freeBytes=free,
                pressureRemaining=None if free is None else free < min_free_bytes,
                diskErrors=disk_errors, observedBytes=before, retainedBytes=total,
                removedBytes=removed, removedEntries=count, changedEntries=skipped,
                unscannedRoots=unscanned, protectedLinks=links,
                accountingComplete=not (unscanned or links or skipped or eviction_errors or disk_errors),
                scanErrors=scan_errors, evictionErrors=eviction_errors, errors=errors)
