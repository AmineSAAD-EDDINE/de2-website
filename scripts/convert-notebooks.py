#!/usr/bin/env python3
import re
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


def write_embed_md(notebook_path: Path, html_relative_path: str) -> None:
    md_path = notebook_path.with_suffix(".md")
    content = f"""---
title: {notebook_path.stem}
publish: true
---

<iframe src=\"/static/{html_relative_path}\" style=\"width:100%;min-height:90vh;border:1px solid #ccc;\"></iframe>
"""
    existing = md_path.read_text(encoding="utf-8") if md_path.exists() else None
    if existing == content:
        return
    md_path.write_text(content, encoding="utf-8")


def replace_ipynb_links() -> None:
    link_regex = re.compile(r"(\[[^\]]*\]\()([^\)]+?\.ipynb)(\))")

    for md_file in CONTENT_ROOT.rglob("*.md"):
        if any(part in EXCLUDE_DIRS for part in md_file.parts):
            continue

        text = md_file.read_text(encoding="utf-8")
        updated = text

        def replace_match(match):
            prefix, target, suffix = match.groups()
            if target.startswith("http://") or target.startswith("https://") or target.startswith("mailto:"):
                return match.group(0)

            target_path = Path(target)
            if not target_path.is_absolute():
                candidate = md_file.parent / target_path
            else:
                candidate = CONTENT_ROOT / target_path.relative_to("/")

            if candidate.exists():
                return f"{prefix}{target_path.with_suffix('.md').as_posix()}{suffix}"
            return match.group(0)

        updated = link_regex.sub(replace_match, text)

        if updated != text:
            print(f"Updating links in {md_file}")
            md_file.write_text(updated, encoding="utf-8")


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

    write_embed_md(notebook, relative.as_posix())

replace_ipynb_links()

print("Notebook conversion and redirect page generation complete.")
