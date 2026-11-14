# SPDX-License-Identifier: GPL-3.0-only
"""Host tests of the exact Python source packaged into the Android runtime."""

from contextlib import redirect_stdout
import html
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "packages/perant_platform/android/src/main/python/text_to_markdown.py"
SPEC = importlib.util.spec_from_file_location("perant_text_to_markdown", SCRIPT)
FORMATTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FORMATTER)


class TextToMarkdownTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="perant-text-task-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "input.json"
        self.destination = self.directory / "output.md"

    def write_request(self, title="会议记录", text="保留中文原文 🐜🚀", schema=1):
        self.source.write_bytes(json.dumps(
            {"schemaVersion": schema, "title": title, "text": text},
            ensure_ascii=False,
        ).encode("utf-8"))

    def run_main(self, source=None, destination=None):
        output = io.StringIO()
        with mock.patch.object(sys, "argv", [
            str(SCRIPT), str(source or self.source),
            str(destination or self.destination),
        ]), redirect_stdout(output):
            FORMATTER.main()
        return output.getvalue()

    def body(self, encoded):
        return encoded.decode("utf-8").split("## 正文\n\n", 1)[1]

    def test_unicode_quotes_and_shell_metacharacters_stay_literal(self):
        marker = self.directory / "this-command-must-not-run"
        text = (f"会议中文 🐜🚀\n$(touch {marker})\n"
                f"`touch {marker}`; '单引号' 和 \"双引号\"\n")
        self.write_request(title="每日会议 🐜", text=text)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.source), str(self.destination)],
            capture_output=True, text=True, check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        markdown = self.destination.read_text(encoding="utf-8")
        self.assertIn("会议中文 🐜🚀", markdown)
        self.assertIn("'单引号' 和 \"双引号\"", markdown)
        self.assertIn("\\`touch ", markdown)
        self.assertIn("$\\(touch ", markdown)
        self.assertFalse(marker.exists())
        self.assertEqual(
            result.stdout,
            f"MARKDOWN_READY:{len(self.destination.read_bytes())}\n",
        )

    def test_markdown_html_links_and_fences_are_visible_source(self):
        source = ("# 不是新标题\n<script>alert(1)</script> & data\n"
                  "[链接](https://example.test/a)\n```python\n"
                  "*斜体* **粗体** _下划线_ | 表格 |\n```\n")
        encoded = FORMATTER.convert("[标题] <raw>", source)
        markdown = encoded.decode("utf-8")
        self.assertTrue(markdown.startswith("# \\[标题\\] &lt;raw&gt;\n"))
        self.assertIn("\\# 不是新标题", markdown)
        self.assertIn("&lt;script&gt;alert\\(1\\)&lt;/script&gt; &amp; data", markdown)
        self.assertNotIn("<script>", markdown)
        self.assertNotIn("\n```", markdown)
        self.assertIn("\\`\\`\\`python", markdown)
        self.assertIn("\\[链接\\]\\(https://example\\.test/a\\)", markdown)

        # Reversing only the published literal escapes recovers every original
        # non-empty source line. This checks visibility, not a new parser copy.
        visible = html.unescape(re.sub(
            r"\\([\\`*_{}\[\]()#+.!|\-])", r"\1", self.body(encoded),
        )).replace("  \n", "\n")
        self.assertEqual(visible, source)

    def test_crlf_empty_paragraphs_and_indentation_preserve_content_order(self):
        encoded = FORMATTER.convert("  标题  ", "首行\r\n  缩进\r\n\r\n\r\n\t末行\r")
        self.assertTrue(encoded.startswith("# 标题\n".encode("utf-8")))
        self.assertNotIn(b"\r", encoded)
        self.assertEqual(
            self.body(encoded),
            "首行  \n&nbsp;&nbsp;缩进\n\n" + "&nbsp;" * 4 + "末行\n",
        )

    def test_twenty_thousand_chinese_characters_and_emoji_are_not_truncated(self):
        for text in ["文" * 20000, "🐜" * 20000]:
            with self.subTest(character=text[0]):
                encoded = FORMATTER.convert("🐜" * 80, text)
                self.assertEqual(self.body(encoded), text + "\n")
                self.assertLessEqual(len(encoded), FORMATTER.MAX_OUTPUT_BYTES)

    def test_invalid_title_text_and_expanded_output_are_rejected(self):
        for title in [None, 3, "", "  ", "a\nb", "a\tb", "a\x7fb", "a\x85b",
                      "a\u2028b", "a\u2029b", "🐜" * 81, "\ud800"]:
            with self.subTest(title=repr(title)):
                with self.assertRaises((ValueError, UnicodeError)):
                    FORMATTER.convert(title, "原文")
        for text in [None, 3, "", " \n", "a\x00b", "文" * 20001,
                     "🐜" * 20001, "\ud800"]:
            with self.subTest(text_type=type(text).__name__):
                with self.assertRaises((ValueError, UnicodeError)):
                    FORMATTER.convert("标题", text)
        # Tabs expand to visible nonbreaking indentation, so the separate
        # output quota remains necessary even for a legal source length.
        with self.assertRaisesRegex(ValueError, "output_too_large"):
            FORMATTER.convert("标题", "\t" * 19999 + "x")

    def test_invalid_json_utf8_and_schema_do_not_create_output(self):
        cases = [
            b"not JSON",
            b"\xff",
            b"[]",
            b"null",
            b"{}",
            b'{"schemaVersion":true,"title":"title","text":"text"}',
            b'{"schemaVersion":1.0,"title":"title","text":"text"}',
            b'{"schemaVersion":2,"title":"title","text":"text"}',
            b'{"schemaVersion":1,"title":null,"text":"text"}',
        ]
        for content in cases:
            with self.subTest(content=content):
                self.source.write_bytes(content)
                with self.assertRaises((ValueError, TypeError, UnicodeError)):
                    self.run_main()
                self.assertFalse(self.destination.exists())
                self.assertFalse(self.destination.with_name("output.md.part").exists())

    def test_input_byte_quota_is_checked_before_parsing(self):
        self.source.write_bytes(b" " * (FORMATTER.MAX_INPUT_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "input_too_large"):
            self.run_main()
        self.assertFalse(self.destination.exists())

    def test_existing_output_or_symlink_cannot_be_overwritten(self):
        self.write_request()
        self.destination.write_text("keep existing result", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "unsafe_file"):
            self.run_main()
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "keep existing result")
        self.destination.unlink()
        missing = self.directory / "not-yet-existing.md"
        self.destination.symlink_to(missing)
        with self.assertRaisesRegex(ValueError, "unsafe_file"):
            self.run_main()
        self.assertTrue(self.destination.is_symlink())
        self.assertFalse(missing.exists())

    def test_symlinked_input_and_wrong_path_contract_are_rejected(self):
        original = self.directory / "source-copy.json"
        original.write_text('{"schemaVersion":1,"title":"t","text":"x"}', encoding="utf-8")
        self.source.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "unsafe_file"):
            self.run_main()
        self.source.unlink()
        self.write_request()
        elsewhere = self.directory / "elsewhere"
        elsewhere.mkdir()
        for source, destination in [
            (original, self.destination),
            (self.source, self.directory / "other.md"),
            (self.source, elsewhere / "output.md"),
        ]:
            with self.subTest(destination=destination):
                with self.assertRaisesRegex(ValueError, "invalid_paths"):
                    self.run_main(source=source, destination=destination)
        self.assertFalse(self.destination.exists())

    def test_output_is_fsynced_and_atomically_published_after_complete_conversion(self):
        self.write_request()
        replace = FORMATTER.os.replace
        fsync = FORMATTER.os.fsync
        published = []

        def inspect_replace(temporary, destination):
            self.assertFalse(self.destination.exists())
            self.assertEqual(Path(temporary), self.directory / "output.md.part")
            data = Path(temporary).read_bytes()
            self.assertEqual(data, FORMATTER.convert("会议记录", "保留中文原文 🐜🚀"))
            published.append(data)
            replace(temporary, destination)

        with mock.patch.object(FORMATTER.os, "fsync", wraps=fsync) as synced, \
                mock.patch.object(FORMATTER.os, "replace", side_effect=inspect_replace):
            stdout = self.run_main()
        synced.assert_called_once()
        self.assertEqual(len(published), 1)
        self.assertEqual(self.destination.read_bytes(), published[0])
        self.assertFalse((self.directory / "output.md.part").exists())
        self.assertEqual(stdout, f"MARKDOWN_READY:{len(published[0])}\n")

    def test_failed_publish_and_preexisting_partial_never_expose_a_final_file(self):
        self.write_request()
        temporary = self.directory / "output.md.part"
        temporary.write_bytes(b"keep existing partial")
        with self.assertRaises(FileExistsError):
            self.run_main()
        self.assertFalse(self.destination.exists())
        self.assertEqual(temporary.read_bytes(), b"keep existing partial")
        temporary.unlink()

        with mock.patch.object(FORMATTER.os, "replace", side_effect=OSError("test publication failure")):
            with self.assertRaises(OSError):
                self.run_main()
        self.assertFalse(self.destination.exists())
        self.assertEqual(
            temporary.read_bytes(),
            FORMATTER.convert("会议记录", "保留中文原文 🐜🚀"),
        )

    def test_cli_failure_does_not_print_private_content_or_paths(self):
        private = "private-source-sentinel-🐜"
        self.write_request(title=private, text="a\x00" + private)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.source), str(self.destination)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "MARKDOWN_FAILED: invalid input or output storage\n")
        self.assertNotIn(private, result.stderr)
        self.assertNotIn(str(self.directory), result.stderr)
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
