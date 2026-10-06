#!/usr/bin/env python3
"""Generate a Rojo-style sourcemap.json from default.project.json + src/.

Used by tools/check.sh so luau-lsp can type-check Roblox-only scripts against the
real Roblox API (it needs the DataModel layout to resolve `ReplicatedStorage.X`
and `script.Parent` requires). Mirrors what `rojo sourcemap` emits for this
project's simple layout: folders, ModuleScripts, Scripts (*.server.luau) and
LocalScripts (*.client.luau).
"""
import json
import os
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def node_for_path(path, name):
    if os.path.isdir(path):
        children = []
        for entry in sorted(os.listdir(path)):
            child = node_for_path(os.path.join(path, entry), None)
            if child:
                children.append(child)
        return {"name": name or os.path.basename(path), "className": "Folder", "children": children}
    base = os.path.basename(path)
    if not base.endswith(".luau"):
        return None
    stem = base[: -len(".luau")]
    class_name = "ModuleScript"
    if stem.endswith(".server"):
        stem, class_name = stem[: -len(".server")], "Script"
    elif stem.endswith(".client"):
        stem, class_name = stem[: -len(".client")], "LocalScript"
    return {
        "name": name or stem,
        "className": class_name,
        "filePaths": [os.path.relpath(path, root)],
    }


def build(name, spec):
    node = {"name": name, "className": spec.get("$className", "Folder"), "children": []}
    if "$path" in spec:
        mapped = node_for_path(os.path.join(root, spec["$path"]), name)
        if mapped:
            mapped["className"] = spec.get("$className", mapped["className"])
            node = mapped
            node.setdefault("children", [])
    for key, value in spec.items():
        if not key.startswith("$"):
            node["children"].append(build(key, value))
    return node


with open(os.path.join(root, "default.project.json")) as f:
    project = json.load(f)
tree = project["tree"]
sourcemap = build(project["name"], tree)
sourcemap["className"] = tree.get("$className", "DataModel")
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "sourcemap.json")
with open(out, "w") as f:
    json.dump(sourcemap, f)
print(out)
