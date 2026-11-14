#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Format a bounded, user-supplied text copy as Markdown; no semantic summary."""

import json
import os
from pathlib import Path
import re
import sys


MAX_TEXT_CHARACTERS = 20_000
MAX_INPUT_BYTES = 192 * 1024
MAX_OUTPUT_BYTES = 256 * 1024


def literal_markdown(value):
    # Text is source material, not Markdown instructions. Keep all punctuation
    # visible, including HTML, links and fences supplied in meeting transcripts.
    value = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return re.sub(r"([\\`*_{}\[\]()#+.!|\-])", r"\\\1", value)


def convert(title, text):
    if not isinstance(title, str) or not title.strip() or len(title) > 80:
        raise ValueError("invalid_title")
    if any(ord(character) < 32 or 127 <= ord(character) <= 159 or character in "\u2028\u2029" for character in title):
        raise ValueError("invalid_title")
    title.encode("utf-8", errors="strict")
    if (not isinstance(text, str) or not text.strip() or "\x00" in text
            or len(text) > MAX_TEXT_CHARACTERS or len(text.encode("utf-8")) > 131072):
        raise ValueError("invalid_text")

    # Normalize platform line endings and collapse repeated empty paragraphs.
    # Preserve every non-empty source line and its order, including indentation.
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    paragraphs = []
    paragraph = []
    for line in lines:
        if not line.strip():
            if paragraph:
                paragraphs.append("  \n".join(paragraph))
                paragraph = []
        else:
            # Leading spaces are nonbreaking so Markdown cannot reinterpret an
            # indented source line as code. All other characters remain visible.
            leading = len(line) - len(line.lstrip(" \t"))
            prefix = "".join("&nbsp;" * (4 if c == "\t" else 1) for c in line[:leading])
            paragraph.append(prefix + literal_markdown(line[leading:]))
    if paragraph:
        paragraphs.append("  \n".join(paragraph))
    markdown = ("# " + literal_markdown(title.strip()) + "\n\n"
                "> 本地文字整理：保留原文，仅规范换行与段落，未生成语义摘要。\n\n"
                "## 正文\n\n" + "\n\n".join(paragraphs) + "\n")
    encoded = markdown.encode("utf-8")
    if len(encoded) > MAX_OUTPUT_BYTES:
        raise ValueError("output_too_large")
    return encoded


def main():
    if len(sys.argv) != 3:
        raise ValueError("invalid_arguments")
    source, destination = (Path(argument) for argument in sys.argv[1:])
    # Paths are fixed by the native bridge; user text never selects a path or
    # becomes Python or shell code. The new task directory must have no output.
    if source.name != "input.json" or destination.name != "output.md" or source.parent != destination.parent:
        raise ValueError("invalid_paths")
    if source.is_symlink() or destination.exists() or destination.is_symlink():
        raise ValueError("unsafe_file")
    with source.open("rb") as input_file:
        data = input_file.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ValueError("input_too_large")
    request = json.loads(data.decode("utf-8", errors="strict"))
    if (not isinstance(request, dict) or type(request.get("schemaVersion")) is not int
            or request["schemaVersion"] != 1):
        raise ValueError("invalid_schema")
    encoded = convert(request.get("title"), request.get("text"))
    temporary = destination.with_name("output.md.part")
    with temporary.open("xb") as output_file:
        output_file.write(encoded)
        output_file.flush()
        os.fsync(output_file.fileno())
    os.replace(temporary, destination)
    print("MARKDOWN_READY:" + str(len(encoded)), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, OSError, UnicodeError):
        # Never print private source text, paths or exception details to logs.
        print("MARKDOWN_FAILED: invalid input or output storage", file=sys.stderr, flush=True)
        sys.exit(2)
