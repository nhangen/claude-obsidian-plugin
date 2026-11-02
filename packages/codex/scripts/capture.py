#!/usr/bin/env python3
"""Installed-package entry point for verified, opt-in Codex capture."""

from pathlib import Path
import runpy
import sys

sys.dont_write_bytecode = True
library = (
    Path(__file__).resolve().parents[1]
    / "skills/commit-capture/scripts/lib/capture-owner.py"
)
runtime = runpy.run_path(str(library))
sys.exit(runtime["codex_main"]())
