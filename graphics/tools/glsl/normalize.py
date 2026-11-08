"""GL 资源命名空间规范化；GL 的 binding 事实另存，不改 Vulkan 缺省路径。"""

import struct

from spirv_msl import KINDS


def resources(path, reflection):
    data = path.read_bytes()
    words = list(struct.unpack(f"<{len(data) // 4}I", data))
    names, types, variables, decorations = {}, {}, {}, {}
    first_type, index = None, 5
    while index < len(words):
        count, opcode = words[index] >> 16, words[index] & 0xFFFF
        if not count or index + count > len(words):
            raise ValueError("SPIR-V 指令越界")
        args = words[index + 1 : index + count]
        if opcode == 5:
            names[args[0]] = struct.pack(f"<{len(args) - 1}I", *args[1:]).split(b"\0")[0].decode()
        elif 19 <= opcode <= 33:
            types[args[0]] = (opcode, args[1:])
            if first_type is None:
                first_type = index
        elif opcode == 59:
            variables[args[1]] = (args[0], args[2])
        elif opcode == 71 and count >= 4:
            decorations.setdefault(args[0], {})[args[1]] = index + 3
        index += count
    targets, result = {}, []
    for namespace, (category, kind) in enumerate(KINDS.items()):
        for binding, resource in enumerate(
            sorted(
                reflection.get(category, []),
                key=lambda item: (item.get("binding", 0), item["name"]),
            )
        ):
            matches = []
            for variable, (pointer, storage) in variables.items():
                if storage not in (0, 2, 12):
                    continue
                pointee = types[pointer][1][1]
                while types[pointee][0] in (28, 29):
                    pointee = types[pointee][1][0]
                if names.get(variable) == resource["name"] or (
                    category in ("ubos", "ssbos") and resource["type"] == f"_{pointee}"
                ):
                    matches.append(variable)
            if len(matches) != 1:
                raise ValueError(f"资源 {resource['name']} 不能唯一对应 SPIR-V 变量")
            variable = matches[0]
            targets[variable] = namespace, binding
            result.append(
                dict(
                    resource,
                    kind=category,
                    resource_kind=kind,
                    gl_binding=resource.get("binding", 0),
                    normalized_set=namespace,
                    normalized_binding=binding,
                )
            )
    additions = []
    for variable, (namespace, binding) in targets.items():
        for decoration, value in ((34, namespace), (33, binding)):
            offset = decorations.get(variable, {}).get(decoration)
            if offset is None:
                additions += [(4 << 16) | 71, variable, decoration, value]
            else:
                words[offset] = value
    words[first_type:first_type] = additions
    path.write_bytes(struct.pack(f"<{len(words)}I", *words))
    return result
