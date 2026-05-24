#!/usr/bin/env python3
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTENT_ROOT = ROOT / "content"
OUTPUT_ROOT = ROOT / "quartz" / "static"

EXCLUDE_DIRS = {"__pycache__", ".ipynb_checkpoints"}

notebooks = [
    p for p in CONTENT_ROOT.rglob("*.ipynb")
    if not any(part in EXCLUDE_DIRS for part in p.parts)
]

if not notebooks:
    print("No notebooks found in content/ to convert.")
    raise SystemExit(0)

for notebook in notebooks:
    relative = notebook.relative_to(CONTENT_ROOT).with_suffix(".html")
    out_dir = OUTPUT_ROOT / relative.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    output_name = relative.stem
    print(f"Converting {notebook} → {out_dir / (output_name + '.html')}")
    result = subprocess.run([
        "python",
        "-m",
        "nbconvert",
        "--to",
        "html",
        "--output-dir",
        str(out_dir),
        "--output",
        output_name,
        str(notebook),
    ])
    if result.returncode != 0:
        raise SystemExit(result.returncode)

print("Notebook conversion complete.")
