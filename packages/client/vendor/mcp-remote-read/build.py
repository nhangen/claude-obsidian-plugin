#!/usr/bin/env python3
"""Rebuild the immutable read bridge from the pinned public npm release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
UPSTREAM_URL = "https://registry.npmjs.org/mcp-remote/-/mcp-remote-0.14.3.tgz"
UPSTREAM_SHA256 = "f4ab0e33b38b24fff6a8b3234f9d683e47995ca44f3186481716d444836f7254"
SOURCE_FILES = (
    "package/LICENSE",
    "package/package.json",
    "package/dist/proxy.js",
    "package/dist/chunk-CGVEK4Z7.js",
    "package/dist/chunk-MLKGABMK.js",
    "package/dist/webapi-WW3GGD26.js",
)
OUTPUT_FILES = (
    "LICENSE",
    "mcp-remote-read.mjs",
    "mcp-remote-read.mjs.LEGAL.txt",
    "THIRD_PARTY_LICENSES.txt",
    "xdg-open",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=cwd, env=env, check=True)


def extract_sources(artifact: Path, destination: Path) -> None:
    with tarfile.open(artifact, "r:gz") as archive:
        members = {
            member.name: member for member in archive.getmembers() if member.isfile()
        }
        missing = set(SOURCE_FILES) - set(members)
        if missing:
            raise ValueError(
                f"upstream artifact is missing: {', '.join(sorted(missing))}"
            )
        for relative in SOURCE_FILES:
            member = members[relative]
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"cannot read upstream member: {relative}")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read())


def package_root(input_path: str) -> str | None:
    marker = "node_modules/"
    if marker not in input_path:
        return None
    tail = input_path.split(marker, 1)[1]
    parts = tail.split("/")
    return "/".join(parts[:2]) if parts[0].startswith("@") else parts[0]


def build_licenses(node_modules: Path, metafile: dict[str, object]) -> str:
    inputs = metafile.get("inputs")
    if not isinstance(inputs, dict):
        raise ValueError("esbuild metafile has no inputs")
    packages = sorted({root for name in inputs if (root := package_root(name))})
    sections: list[str] = []
    for package in packages:
        package_dir = node_modules / package
        metadata = json.loads(
            (package_dir / "package.json").read_text(encoding="utf-8")
        )
        license_paths = sorted(
            path
            for path in package_dir.iterdir()
            if path.is_file()
            and path.name.lower().startswith(("license", "licence", "copying"))
        )
        heading = f"===== {metadata['name']}@{metadata['version']} ({metadata.get('license', 'unspecified')}) ====="
        if license_paths:
            body = "\n\n".join(
                path.read_text(encoding="utf-8", errors="replace").rstrip()
                for path in license_paths
            )
        else:
            body = f"License expression: {metadata.get('license', 'unspecified')}"
        sections.append(f"{heading}\n{body}")
    return "\n\n".join(sections) + "\n"


def validate_metafile(metafile: dict[str, object]) -> None:
    outputs = metafile.get("outputs")
    if not isinstance(outputs, dict):
        raise ValueError("esbuild metafile has no outputs")
    bundles = [
        value for name, value in outputs.items() if name.endswith("mcp-remote-read.mjs")
    ]
    if len(bundles) != 1:
        raise ValueError("esbuild emitted an unexpected output set")
    output = bundles[0]
    imports = output.get("imports") if isinstance(output, dict) else None
    if not isinstance(imports, list):
        raise ValueError("esbuild metafile has no output imports")
    builtins = set(
        json.loads(
            subprocess.check_output(
                [
                    "node",
                    "-e",
                    "console.log(JSON.stringify(require('node:module').builtinModules))",
                ],
                text=True,
            )
        )
    )
    builtins.update(f"node:{name}" for name in tuple(builtins))
    external_paths = [
        item["path"]
        for item in imports
        if isinstance(item, dict)
        and item.get("external")
        and isinstance(item.get("path"), str)
        and item["path"] not in builtins
    ]
    if external_paths:
        recognized_builtins = set(
            json.loads(
                subprocess.check_output(
                    [
                        "node",
                        "-e",
                        "const { isBuiltin } = require('node:module');"
                        "const paths = JSON.parse(process.argv[1]);"
                        "console.log(JSON.stringify(paths.filter((p) => isBuiltin?.(p))));",
                        json.dumps(external_paths),
                    ],
                    text=True,
                )
            )
        )
        builtins.update(recognized_builtins)
    bad = [
        item
        for item in imports
        if isinstance(item, dict)
        and item.get("external")
        and item.get("path") not in builtins
    ]
    if bad:
        raise ValueError(f"bundle retains non-Node external imports: {bad}")
    for required in ("chunk-CGVEK4Z7.js", "node_modules/open/", "node_modules/undici/"):
        if not any(required in name for name in metafile.get("inputs", {})):
            raise ValueError(f"bundle metafile omitted required input: {required}")


def build(artifact: Path, destination: Path, npm_cache: Path) -> None:
    if sha256(artifact) != UPSTREAM_SHA256:
        raise ValueError("upstream tarball hash mismatch")
    with tempfile.TemporaryDirectory(prefix="obsidian-mcp-read-build.") as raw_temp:
        temp = Path(raw_temp)
        extract_sources(artifact, temp)
        run(
            [
                "patch",
                "-p0",
                "--fuzz=0",
                "-i",
                str(ROOT / "mcp-remote-0.14.3-session-recovery.patch"),
            ],
            cwd=temp,
        )
        build_root = temp / "build"
        build_root.mkdir()
        shutil.copy2(ROOT / "build-package.json", build_root / "package.json")
        shutil.copy2(ROOT / "build-package-lock.json", build_root / "package-lock.json")
        env = {**os.environ, "npm_config_cache": str(npm_cache)}
        run(
            ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
            cwd=build_root,
            env=env,
        )
        output = temp / "output"
        output.mkdir()
        bundle = output / "mcp-remote-read.mjs"
        metafile_path = temp / "metafile.json"
        esbuild = build_root / "node_modules/.bin/esbuild"
        run(
            [
                str(esbuild),
                str(temp / "package/dist/proxy.js"),
                "--bundle",
                "--platform=node",
                "--format=esm",
                "--target=node22",
                "--legal-comments=external",
                '--banner:js=import { createRequire as __obsidianCreateRequire } from "node:module"; const require = __obsidianCreateRequire(import.meta.url);',
                f"--outfile={bundle}",
                f"--metafile={metafile_path}",
            ],
            cwd=build_root,
            env={**os.environ, "NODE_PATH": str(build_root / "node_modules")},
        )
        metafile = json.loads(metafile_path.read_text(encoding="utf-8"))
        validate_metafile(metafile)
        bundle_text = bundle.read_text(encoding="utf-8")
        for marker in (
            "OAuthProtectedResourceMetadataSchema",
            "authorization_endpoint",
            "application/jose",
        ):
            if marker not in bundle_text:
                raise ValueError(f"bundle omitted OAuth/web API marker: {marker}")
        shutil.copy2(temp / "package/LICENSE", output / "LICENSE")
        xdg_open = build_root / "node_modules/open/xdg-open"
        shutil.copy2(xdg_open, output / "xdg-open")
        (output / "xdg-open").chmod(0o755)
        (output / "THIRD_PARTY_LICENSES.txt").write_text(
            build_licenses(build_root / "node_modules", metafile), encoding="utf-8"
        )
        destination.mkdir(parents=True, exist_ok=True)
        for relative in OUTPUT_FILES:
            shutil.copy2(output / relative, destination / relative)
        (destination / "xdg-open").chmod(0o755)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="obsidian-mcp-read-source.") as raw_temp:
        temp = Path(raw_temp)
        artifact = args.artifact
        if artifact is None:
            artifact = temp / "mcp-remote-0.14.3.tgz"
            with urllib.request.urlopen(UPSTREAM_URL, timeout=30) as response:
                artifact.write_bytes(response.read())
        build(artifact.resolve(), args.output.resolve(), temp / "npm-cache")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"obsidian-mcp-read-build: {error}", file=os.sys.stderr)
        raise SystemExit(1)
