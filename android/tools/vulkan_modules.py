"""Read the existing NSO symbols to identify replaceable Vulkan loader/driver modules."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def replaced_modules(exefs):
    sys.path.insert(0, str(ROOT / "graphics/nvn/tools"))
    try:
        from nso_syms import load, dynsyms
    finally:
        sys.path.pop(0)
    symbols = {}
    for path in sorted(Path(exefs).iterdir()):
        if path.name not in {"main", "sdk", *(f"subsdk{i}" for i in range(10))} or not path.is_file():
            continue
        rows = dynsyms(load(str(path)))
        symbols[path.name] = ({name for name, defined, _ in rows if not defined},
                              {name for name, defined, bind in rows if defined and bind in (1, 2)})
    main = symbols.get("main", (set(), set()))[0]
    if not any(n.startswith("vk") for n in main) or any(n.startswith(("nvn", "egl")) for n in main):
        raise ValueError("direct Vulkan requires Vulkan main imports without NVN/EGL")
    replaced = [name for name, (imports, exports) in symbols.items() if name.startswith("subsdk") and
                ("vkGetInstanceProcAddr" in exports or "vk_icdGetInstanceProcAddr" in exports)]
    # Drivers may provide non-graphics helpers used by remaining modules. Refuse
    # such a closure rather than silently dropping their imports.
    kept_exports = set().union(*(e for n, (_, e) in symbols.items() if n not in replaced))
    driver_exports = set().union(*(symbols[n][1] for n in replaced))
    for name, (imports, _) in symbols.items():
        if name not in replaced:
            missing = imports & driver_exports - kept_exports
            missing = {n for n in missing if not n.startswith("vk")}
            if missing:
                raise ValueError("driver supplies non-Vulkan imports: " + ", ".join(sorted(missing)))
    return replaced
