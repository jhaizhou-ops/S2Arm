#!/usr/bin/env python3
"""Validate the A0 v1 sample set with a small stdlib-only JSON Schema subset.

Usage:
    python3 android/contracts/validate.py [samples-dir]

This is intentionally not a general JSON Schema implementation. It covers the
keywords used by the A0 schemas: type, required, properties,
additionalProperties, propertyNames, const, enum, pattern, minLength, minItems,
uniqueItems, items, oneOf, minimum and exclusiveMinimum. It then checks capability
requirements and cross-file invariants that a JSON Schema cannot express.
"""
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from module_order import is_load_order   # Horizon 装载序（main → subsdk0..N → sdk）：排序规则只有这一份


class Invalid(Exception):
    pass


# Add a feature only when this consumer implements and validates its semantics.
ANDROID_INPUT_ROLES = 's2arm.android-input-roles-v1'
SUPPORTED_FEATURES = frozenset([ANDROID_INPUT_ROLES])


def _is_type(value, name):
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    raise Invalid(f"validator does not know type {name!r}")


def check(value, schema, path="$"):
    if "oneOf" in schema:
        ok = 0
        errors = []
        for sub in schema["oneOf"]:
            try:
                check(value, sub, path)
                ok += 1
            except Invalid as e:
                errors.append(str(e))
        if ok != 1:
            raise Invalid(f"{path}: oneOf matched {ok} branches ({'; '.join(errors)})")
        return
    if "const" in schema and value != schema["const"]:
        raise Invalid(f"{path}: expected {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise Invalid(f"{path}: {value!r} not in {schema['enum']!r}")
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, n) for n in names):
            raise Invalid(f"{path}: expected type {names}, got {type(value).__name__}")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            raise Invalid(f"{path}: shorter than {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise Invalid(f"{path}: {value!r} does not match {schema['pattern']!r}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise Invalid(f"{path}: {value} < minimum {schema['minimum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            raise Invalid(f"{path}: {value} <= exclusiveMinimum {schema['exclusiveMinimum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                raise Invalid(f"{path}: missing required {key!r}")
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            if "propertyNames" in schema:
                check(key, schema["propertyNames"], f"{path} property name")
            if key in props:
                check(item, props[key], f"{path}.{key}")
            elif extra is False:
                raise Invalid(f"{path}: unexpected property {key!r}")
            elif isinstance(extra, dict):
                check(item, extra, f"{path}.{key}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            raise Invalid(f"{path}: fewer than {schema['minItems']} items")
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(value):
                check(item, item_schema, f"{path}[{i}]")
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            raise Invalid(f"{path}: duplicate items")


def check_document(value, schema, path):
    check(value, schema, path)
    for feature in value.get("requiredFeatures", []):
        if feature not in SUPPORTED_FEATURES:
            raise Invalid(f"{path}: unsupported required feature {feature!r}")
    if ANDROID_INPUT_ROLES in value.get("requiredFeatures", []):
        if value.get("target") == "android":
            if "input" not in value:
                raise Invalid("role-aware artifact has no input")
        else:
            check_input_roles(value)


def check_input_roles(manifest):
    """Validate the complete declared source/role mapping, never just its name."""
    try:
        roles = manifest["extensions"]["s2arm.android-input"]
        if set(roles) != {"version", "sources", "modules"} or type(roles["version"]) is not int or roles["version"] != 1:
            raise Invalid("invalid Android input role extension")
        sources = roles["sources"]
        if not isinstance(sources, list) or not sources:
            raise Invalid("missing source identities")
        source_keys = set()
        for source in sources:
            if (not isinstance(source, dict) or set(source) != {"type", "sha256"} or
                    source["type"] not in ("nsp", "xci") or not isinstance(source["sha256"], str) or
                    not re.fullmatch(r"[0-9a-f]{64}", source["sha256"])):
                raise Invalid("invalid public source identity")
            key = (source["type"], source["sha256"])
            if key in source_keys:
                raise Invalid("duplicate public source identity")
            source_keys.add(key)
        modules = module_index(manifest["modules"], "input")
        entries = roles["modules"]
        if not isinstance(entries, list):
            raise Invalid("invalid module role table")
        seen = set()
        initial = {"main", "sdk"} | {f"subsdk{i}" for i in range(10)}
        for item in entries:
            if not isinstance(item, dict) or set(item) != {"name", "sourceType", "sourcePath", "role"}:
                raise Invalid("invalid module role")
            name, kind, path, role = (item[k] for k in ("name", "sourceType", "sourcePath", "role"))
            if not isinstance(name, str) or name in seen or name not in modules or kind != modules[name]["type"]:
                raise Invalid("module role does not uniquely match source")
            seen.add(name)
            if (not isinstance(path, str) or "\\" in path or path.startswith("/") or
                    any(part in ("", ".", "..") for part in path.split("/"))):
                raise Invalid("unsafe module source path")
            if kind == "exefs" and path != "exefs/" + name:
                raise Invalid("exefs module path differs from its name")
            if kind == "nro" and not path.startswith(("romfs/", "aoc/", "control/")):
                raise Invalid("unsupported NRO path")
            expected = "initial" if kind == "exefs" and name in initial else "unresolved"
            if role != expected:
                raise Invalid("module execution role is unsupported")
        if seen != set(modules) or "main" not in seen:
            raise Invalid("module role table is incomplete")
    except (KeyError, TypeError, AttributeError) as e:
        raise Invalid("missing Android input role data") from e


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def check_artifact_modules(art):
    mods = art.get("modules", [])
    module_index(mods, "artifact")
    # modules 顺序 = 装载顺序（BootContract → load_modules_from_source → loader.c 全局符号解析）：非 Horizon 序拒收
    if not is_load_order(m["name"] for m in mods):
        raise Invalid("artifact modules are not in Horizon load order (main, subsdk0..N, sdk)")
    for m in mods:
        stem = m["image"][:-len(".patched.bin")]
        if stem.rsplit("/", 1)[-1] != m["name"]:
            raise Invalid(f"module {m['name']} image does not match its name")
        for key, suffix in (("fixups", ".fixups.tsv"), ("gates", ".gates.tsv")):
            if m[key] != stem + suffix:
                raise Invalid(f"module {m['name']} {key} must be {stem + suffix!r}")
    apk_mods = [m for m in mods if m.get("source") == "apk-asset"]
    if apk_mods and "apk" not in art:
        raise Invalid("modules use apk-asset but artifact has no apk object")
    if "apk" in art:
        apk = art["apk"]
        want = "org.s2arm.game.t" + art["titleId"].lower()
        if apk.get("packageName") not in (want, want + ".w2"):
            raise Invalid(f"apk.packageName must be {want} with only the optional .w2 test suffix")
        if apk.get("versionCode", 0) < 1:
            raise Invalid("apk.versionCode is not positive")


def module_index(modules, what):
    out = {}
    for module in modules:
        name = module["name"]
        if name in out:
            raise Invalid(f"{what}: duplicate module {name!r}")
        out[name] = module
    return out


def check_artifact_input(art, revision):
    if "input" not in art:
        if ANDROID_INPUT_ROLES in art.get("requiredFeatures", []):
            raise Invalid("role-aware artifact has no input")
        return
    inp = art["input"]
    rel = inp["manifest"]
    if rel.startswith("/") or ".." in rel.split("/"):
        raise Invalid(f"unsafe input manifest path {rel!r}")
    path = os.path.join(revision, rel)
    try:
        with open(path, "rb") as stream:
            raw = stream.read()
    except OSError as e:
        raise Invalid(f"input manifest is missing: {e}")
    if hashlib.sha256(raw).hexdigest() != inp["manifestSha256"]:
        raise Invalid("input manifest does not match input.manifestSha256")
    manifest = json.loads(raw.decode("utf-8"))
    here = os.path.dirname(os.path.abspath(__file__))
    check_document(manifest, load(os.path.join(here, "game-input-manifest.v1.schema.json")), rel)
    if ((ANDROID_INPUT_ROLES in manifest.get("requiredFeatures", [])) !=
            (ANDROID_INPUT_ROLES in art.get("requiredFeatures", []))):
        raise Invalid("artifact and input role capabilities differ")
    if ANDROID_INPUT_ROLES in manifest.get("requiredFeatures", []):
        if any(item["role"] != "initial" for item in manifest["extensions"]["s2arm.android-input"]["modules"]):
            raise Invalid("unresolved source module cannot be declared built")
        # Legacy v1 inputs remain readable. New role-aware inputs must be
        # members of the exact index named by the artifact and completion file.
        revision_root = os.path.realpath(revision)
        if os.path.realpath(path) != os.path.join(revision_root, rel):
            raise Invalid("input manifest path is redirected")
        try:
            for metadata in ("index.tsv", "manifest.json"):
                full = os.path.join(revision_root, metadata)
                if os.path.realpath(full) != full:
                    raise Invalid("input index metadata is redirected")
            with open(os.path.join(revision_root, "index.tsv"), "rb") as stream:
                index = stream.read()
            completion = load(os.path.join(revision_root, "manifest.json"))
            index_hash = hashlib.sha256(index).hexdigest()
            if (art["package"]["indexSha256"] != index_hash or art["contentRoot"] != "sha256-" + index_hash or
                    completion.get("version") != 2 or completion.get("index_sha256") != index_hash):
                raise Invalid("input index is not bound to artifact and completion manifest")
            names = set()
            found = False
            for line in index.decode("utf-8").splitlines():
                fields = line.split("\t")
                if len(fields) != 3 or fields[0] in names:
                    raise Invalid("invalid or duplicate input index row")
                names.add(fields[0])
                if fields[0] == rel:
                    found = fields[1] == str(len(raw)) and fields[2] == inp["manifestSha256"]
            if not found:
                raise Invalid("input manifest is missing from the index")
        except (OSError, ValueError, KeyError, UnicodeError) as error:
            raise Invalid("cannot verify indexed input manifest") from error
    if inp["titleId"] != art["titleId"] or manifest["titleId"] != art["titleId"]:
        raise Invalid("input.titleId != artifact.titleId")
    if inp["contentRoot"] != manifest["romfs"]["contentRoot"]:
        raise Invalid("input.contentRoot != input manifest romfs.contentRoot")
    built = module_index(art["modules"], "artifact")
    inputs = module_index(manifest["modules"], "input")
    if built.keys() != inputs.keys():
        raise Invalid("input and artifact module names differ")
    for name, im in inputs.items():
        if built[name].get("buildId") != im["buildId"]:
            raise Invalid(f"input module {name} buildId differs from artifact or is missing")


def check_job_pair(request, event):
    expected = request.get("jobId", request["taskId"])
    if event["jobId"] != expected:
        raise Invalid("job event jobId != job request taskId/jobId")


def validate_file(schema_path, sample_path):
    schema = load(schema_path)
    sample = load(sample_path)
    check_document(sample, schema, os.path.basename(sample_path))
    return sample


def validate_game(root):
    root = os.path.abspath(root)
    here = os.path.dirname(os.path.abspath(__file__))
    cur = load(os.path.join(root, "current.json"))
    check_document(cur, load(os.path.join(here, "current.v1.schema.json")), "current.json")
    if cur["titleId"] != os.path.basename(root):
        raise Invalid(f"game directory is {os.path.basename(root)}, expected {cur['titleId']}")
    if cur["revisionDir"] != "revisions/" + cur["contentRoot"]:
        raise Invalid("current.revisionDir != revisions/<contentRoot>")
    rel = cur["artifact"]
    if rel.startswith("/") or ".." in rel.split("/"):
        raise Invalid(f"unsafe artifact path {rel!r}")
    revision = os.path.join(root, cur["revisionDir"])
    artifact_path = os.path.join(revision, rel)
    art = load(artifact_path)
    check_document(art, load(os.path.join(here, "game-build-artifact.v1.schema.json")), rel)
    for key in ("titleId", "contentRoot"):
        if cur[key] != art[key]:
            raise Invalid(f"current.{key} != artifact.{key}")
    if art["rewriteAbi"] != "android-sp-safe-v1":
        raise Invalid("artifact.rewriteAbi is not android-sp-safe-v1")
    h = hashlib.sha256()
    with open(artifact_path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    if h.hexdigest() != cur["artifactSha256"]:
        raise Invalid("artifact does not match artifactSha256")
    check_artifact_modules(art)
    check_artifact_input(art, revision)
    print(f"ok game {root} ({art['titleId']}, {len(art['modules'])} module(s))")
    return 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    if len(sys.argv) == 3 and sys.argv[1] == "--game":
        try:
            return validate_game(sys.argv[2])
        except (OSError, ValueError, KeyError, Invalid) as e:
            print(f"FAILED game {sys.argv[2]}: {e}")
            return 1
    samples = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "samples")
    files = {
        "current": (os.path.join(here, "current.v1.schema.json"), os.path.join(samples, "current.json")),
        "artifact": (os.path.join(here, "game-build-artifact.v1.schema.json"), os.path.join(samples, "game-build-artifact.json")),
        "input": (os.path.join(here, "game-input-manifest.v1.schema.json"), os.path.join(samples, "game-input-manifest.json")),
        "boot": (os.path.join(here, "boot-spec.v1.schema.json"), os.path.join(samples, "boot-spec.json")),
    }
    run_sample = os.path.join(samples, "run-manifest.json")
    if os.path.exists(run_sample):
        files["run"] = (os.path.join(here, "run-manifest.v1.schema.json"), run_sample)
    job_request_sample = os.path.join(samples, "job-request.json")
    job_event_sample = os.path.join(samples, "job-event.json")
    if os.path.exists(job_request_sample):
        files["job_request"] = (os.path.join(here, "job-request.v1.schema.json"), job_request_sample)
    if os.path.exists(job_event_sample):
        files["job_event"] = (os.path.join(here, "job-event.v1.schema.json"), job_event_sample)
    docs = {}
    failed = 0
    for name, (schema, sample) in files.items():
        try:
            docs[name] = validate_file(schema, sample)
            if name == "artifact":
                check_artifact_modules(docs[name])
            print(f"ok {os.path.relpath(sample, here)}")
        except (OSError, ValueError, Invalid) as e:
            failed += 1
            print(f"FAILED {os.path.relpath(sample, here)}: {e}")

    if not failed:
        cur, art, boot = docs["current"], docs["artifact"], docs["boot"]
        run = docs.get("run")
        job_request = docs.get("job_request")
        job_event = docs.get("job_event")
        try:
            check_artifact_input(art, samples)
            for key in ("titleId", "contentRoot"):
                if not (cur[key] == art[key] == boot[key]):
                    raise Invalid(f"cross-file: {key} differs")
            expected_revision = "revisions/" + cur["contentRoot"]
            if cur["revisionDir"] != expected_revision:
                raise Invalid("current.revisionDir != revisions/<contentRoot>")
            if boot["revisionDir"] != expected_revision:
                raise Invalid("boot.revisionDir != revisions/<contentRoot>")
            if not (cur["artifact"] == boot["artifact"] == "game-build-artifact.json"):
                raise Invalid("artifact name differs or is not game-build-artifact.json")
            if cur["artifactSha256"] != boot["artifactSha256"]:
                raise Invalid("current.artifactSha256 != boot.artifactSha256")
            with open(os.path.join(samples, cur["artifact"]), "rb") as f:
                if hashlib.sha256(f.read()).hexdigest() != cur["artifactSha256"]:
                    raise Invalid("sample artifact does not match artifactSha256")
            if art["rewriteAbi"] != "android-sp-safe-v1":
                raise Invalid("sample artifact must use the current rewrite ABI")
            if run is not None:
                if run["artifact"]["artifactSha256"] != cur["artifactSha256"]:
                    raise Invalid("run artifactSha256 != current.artifactSha256")
                for key in ("titleId", "contentRoot"):
                    if run["artifact"][key] != cur[key]:
                        raise Invalid(f"run artifact.{key} != current.{key}")
                if run["artifact"]["artifact"] != cur["artifact"]:
                    raise Invalid("run artifact name != current.artifact")
                if run["input"]["manifestSha256"] != art["input"]["manifestSha256"]:
                    raise Invalid("run input.manifestSha256 != artifact.input.manifestSha256")
                if run["input"]["contentRoot"] != art["input"]["contentRoot"]:
                    raise Invalid("run input.contentRoot != artifact.input.contentRoot")
                built = {m["name"]: m for m in art["modules"]}
                ran = {m["name"]: m for m in run["modules"]}
                if built.keys() != ran.keys():
                    raise Invalid("run and artifact module names differ")
                for name in built:
                    if built[name].get("buildId") != ran[name]["buildId"]:
                        raise Invalid(f"run module {name} buildId differs from artifact")
                    if built[name].get("source") != ran[name]["source"]:
                        raise Invalid(f"run module {name} source differs from artifact")
            if job_request is not None and job_event is not None:
                check_job_pair(job_request, job_event)
            print("ok cross-file invariants")
        except (OSError, Invalid) as e:
            failed += 1
            print(f"FAILED cross-file: {e}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
