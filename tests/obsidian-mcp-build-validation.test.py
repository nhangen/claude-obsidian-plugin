#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD_PY = ROOT / "packages/client/vendor/mcp-remote-read/build.py"

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("obsidian_mcp_read_build", BUILD_PY)
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)

OLD_NODE_PRELOAD = "delete require('node:module').isBuiltin;\n"

STUB = """#!/usr/bin/env python3
import json
import os
import sys


def reject(message):
    sys.stderr.write("node stub: %s\\n" % (message,))
    sys.exit(9)


def record(entry):
    with open(os.environ["OBSIDIAN_MCP_BUILD_STUB_LOG"], "a", encoding="utf-8") as log:
        log.write(json.dumps(entry) + "\\n")


builtin_modules = json.loads(os.environ["OBSIDIAN_MCP_BUILD_STUB_BUILTIN_MODULES"])
argv = sys.argv[1:]
if len(argv) == 2 and argv[0] == "-e" and "builtinModules" in argv[1]:
    record({"builtin_probe": True})
    print(json.dumps(builtin_modules))
elif len(argv) == 3 and argv[0] == "-e" and "isBuiltin" in argv[1]:
    try:
        paths = json.loads(argv[2])
    except ValueError as error:
        reject("unparseable paths payload: %s" % (error,))
    if not isinstance(paths, list) or any(not isinstance(p, str) for p in paths):
        reject("unexpected paths payload: %r" % (paths,))
    record({"isbuiltin_probe": True, "paths": paths})
    if os.environ["OBSIDIAN_MCP_BUILD_STUB_MODE"] == "old":
        os.execv(
            os.environ["OBSIDIAN_MCP_BUILD_STUB_REAL_NODE"],
            [os.environ["OBSIDIAN_MCP_BUILD_STUB_REAL_NODE"], "-r", os.environ["OBSIDIAN_MCP_BUILD_STUB_PRELOAD"]] + argv,
        )
    else:
        print(json.dumps([p for p in paths if p == "node:sqlite" or p in builtin_modules]))
else:
    reject("unexpected argv shape: %r" % (sys.argv,))
"""


def node_sqlite_ready():
    try:
        answer = subprocess.check_output(
            ["node", "-e", "console.log(require('node:module').isBuiltin('node:sqlite'))"],
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return False
    return answer == "true"


def metafile(paths):
    imports = []
    for path in paths:
        if isinstance(path, str):
            imports.append({"path": path, "kind": "import-statement", "external": True})
        else:
            imports.append(path)
    return {
        "outputs": {"out/mcp-remote-read.mjs": {"imports": imports}},
        "inputs": {
            "dist/chunk-CGVEK4Z7.js": {"bytesInOutput": 10},
            "node_modules/open/index.js": {"bytesInOutput": 1},
            "node_modules/undici/lib/client.js": {"bytesInOutput": 1},
        },
    }


class ValidateMetafileIsBuiltinTests(unittest.TestCase):
    def install_node_stub(self, mode, builtin_modules):
        stub_dir = Path(tempfile.mkdtemp(prefix="node-stub."))
        self.addCleanup(shutil.rmtree, stub_dir, True)
        stub = stub_dir / "node"
        stub.write_text(STUB, encoding="utf-8")
        stub.chmod(0o755)
        log_path = stub_dir / "node-calls.log"
        preload = stub_dir / "preload.js"
        preload.write_text(OLD_NODE_PRELOAD, encoding="utf-8")
        real_node = shutil.which("node")
        saved_path = os.environ["PATH"]
        os.environ["PATH"] = f"{stub_dir}{os.pathsep}{saved_path}"
        os.environ["OBSIDIAN_MCP_BUILD_STUB_MODE"] = mode
        os.environ["OBSIDIAN_MCP_BUILD_STUB_BUILTIN_MODULES"] = json.dumps(builtin_modules)
        os.environ["OBSIDIAN_MCP_BUILD_STUB_LOG"] = str(log_path)
        os.environ["OBSIDIAN_MCP_BUILD_STUB_PRELOAD"] = str(preload)
        os.environ["OBSIDIAN_MCP_BUILD_STUB_REAL_NODE"] = real_node
        self.addCleanup(os.environ.update, PATH=saved_path)
        for name in (
            "OBSIDIAN_MCP_BUILD_STUB_MODE",
            "OBSIDIAN_MCP_BUILD_STUB_BUILTIN_MODULES",
            "OBSIDIAN_MCP_BUILD_STUB_LOG",
            "OBSIDIAN_MCP_BUILD_STUB_PRELOAD",
            "OBSIDIAN_MCP_BUILD_STUB_REAL_NODE",
        ):
            self.addCleanup(os.environ.pop, name, None)
        return log_path

    @staticmethod
    def stub_calls(log_path):
        return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]

    @unittest.skipUnless(node_sqlite_ready(), "node:sqlite is unavailable on this node; the supported runtime is node22")
    def test_node_sqlite_external_accepted(self):
        build.validate_metafile(metafile(["node:sqlite", {"path": "chunk-MLKGABMK.js", "kind": "import-statement"}]))

    def test_node_sqlite_external_resolves_through_isbuiltin_fallback(self):
        log_path = self.install_node_stub("modern", ["assert", "crypto", "fs", "http", "path", "url", "zlib"])
        build.validate_metafile(metafile(["node:sqlite"]))
        calls = self.stub_calls(log_path)
        self.assertEqual(2, len(calls))
        self.assertTrue(calls[0]["builtin_probe"])
        self.assertTrue(calls[1]["isbuiltin_probe"])
        self.assertEqual(["node:sqlite"], calls[1]["paths"])

    def test_non_builtin_external_rejected(self):
        with self.assertRaises(ValueError) as raised:
            build.validate_metafile(metafile(["some-package/dist/index.mjs"]))
        self.assertIn("some-package/dist/index.mjs", str(raised.exception))

    def test_non_builtin_external_rejected_on_stubbed_node(self):
        log_path = self.install_node_stub("modern", ["assert", "crypto", "fs", "http", "path", "url", "zlib"])
        with self.assertRaises(ValueError) as raised:
            build.validate_metafile(metafile(["some-package/dist/index.mjs"]))
        calls = self.stub_calls(log_path)
        self.assertEqual(2, len(calls))
        self.assertIn("some-package/dist/index.mjs", str(raised.exception))

    def test_isbuiltin_absent_on_old_node_fails_closed(self):
        log_path = self.install_node_stub("old", ["assert", "crypto", "fs", "http", "path", "url", "zlib"])
        with self.assertRaises(ValueError) as raised:
            build.validate_metafile(metafile(["node:sqlite"]))
        calls = self.stub_calls(log_path)
        self.assertEqual(2, len(calls))
        self.assertEqual(["node:sqlite"], calls[1]["paths"])
        self.assertIn("node:sqlite", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
