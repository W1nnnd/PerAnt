# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the actual Office launcher generator without running the desktop."""

import ast
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
STARTUP = ROOT / "packages/perant_platform/android/src/main/desktop/start_desktop.sh"
OFFICE_EXECUTABLE = "/usr/lib/libreoffice/program/soffice.bin"
OFFICE_APPS = ("writer", "calc", "impress")


class DesktopInstallationIdentityTests(unittest.TestCase):
    def test_ui_can_change_without_accepting_another_installed_userspace(self):
        digest = runpy.run_path(str(ROOT / "tool/prepare-linux-runtime"))["desktop_base_digest"]
        old = {"sha256": "5a4e3867a63d8256ee380ae75ab71568d4c68fbf759d3e339a3d6241bb84e73d",
               "sizeBytes": 30319, "version": 1}
        manifest = {"desktop": {"startupScript": old.copy(), "packages": ["xfwm4"]},
                    "loader": {"sha256": "a" * 64}}
        previous = hashlib.sha256((json.dumps(manifest, indent=2) + "\n").encode()).hexdigest()
        manifest["desktop"]["startupScript"].update(sizeBytes=100, sha256="b" * 64)
        manifest["desktopBaseSha256"] = digest(manifest)
        self.assertEqual(previous, digest(manifest))
        manifest["loader"]["sha256"] = "c" * 64
        self.assertNotEqual(previous, digest(manifest))
        manifest["loader"]["sha256"] = "a" * 64
        manifest["desktop"]["packages"].append("another-package")
        self.assertNotEqual(previous, digest(manifest))


def load_launcher_generator():
    """Compile only the pure generator function, never the session setup code."""
    source = STARTUP.read_text(encoding="utf-8")
    embedded = re.search(r"<<'PY'\n(.*?)\nPY(?:\n|$)", source, re.DOTALL)
    if embedded is None:
        raise AssertionError("Desktop startup's embedded Python was not found")
    module = ast.parse(embedded.group(1), filename=str(STARTUP))
    generators = [node for node in module.body
                  if isinstance(node, ast.FunctionDef) and node.name == "office_launcher"]
    commands = [node.value for node in module.body
                if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == "commands"
                        for target in node.targets)]
    if len(generators) != 1 or len(commands) != 1:
        raise AssertionError("Expected one Office launcher generator and command map")
    namespace = {}
    generator_module = ast.Module(body=generators, type_ignores=[])
    exec(compile(generator_module, str(STARTUP), "exec"), namespace)
    return namespace["office_launcher"], ast.literal_eval(commands[0])


class DesktopOfficeLauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        generator, cls.commands = load_launcher_generator()
        cls.generate = staticmethod(generator)

    def test_actual_generated_office_launchers_have_valid_shell_syntax(self):
        with tempfile.TemporaryDirectory(prefix="perant-office-syntax-") as directory:
            for app in OFFICE_APPS:
                with self.subTest(app=app):
                    launcher = Path(directory) / ("launch-" + app)
                    launcher.write_text(self.generate(self.commands[app]), encoding="utf-8")
                    result = subprocess.run(
                        ["/bin/sh", "-n", str(launcher)],
                        capture_output=True, text=True, check=False, timeout=5,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_restart_bounds_arguments_environment_and_child_output(self):
        cases = (
            ((0,), 0, 1),
            ((81, 0), 0, 2),
            ((81, 81, 0), 0, 3),
            ((81, 81, 81, 0), 81, 3),
            ((79, 0), 79, 1),
            ((77, 0), 77, 1),
            ((139, 0), 139, 1),
        )
        for app in OFFICE_APPS:
            for exits, expected_status, expected_launches in cases:
                with self.subTest(app=app, child_exits=exits):
                    self.check_child_runs(app, exits, expected_status, expected_launches)

    def check_child_runs(self, app, exits, expected_status, expected_launches):
        with tempfile.TemporaryDirectory(prefix="perant-office-launcher-") as directory:
            workspace = Path(directory).resolve()
            calls = workspace / "calls.jsonl"
            child = workspace / "fake office.py"
            child.write_text(
                "import hashlib, json, os, pathlib, sys\n"
                "path = pathlib.Path(os.environ['PERANT_TEST_CALLS'])\n"
                "previous = path.read_text().splitlines() if path.exists() else []\n"
                "attempt = len(previous) + 1\n"
                "record = {'argv': sys.argv[1:], 'cwd': os.getcwd(),\n"
                "          'locking': os.environ.get('SAL_ENABLE_FILE_LOCKING'),\n"
                "          'plugin': os.environ.get('SAL_USE_VCLPLUGIN'),\n"
                "          'sentinel': os.environ.get('PERANT_TEST_SENTINEL'),\n"
                "          'environmentHash': hashlib.sha256(json.dumps(\n"
                "              dict(os.environ), sort_keys=True).encode()).hexdigest()}\n"
                "with path.open('a') as stream: stream.write(json.dumps(record) + '\\n')\n"
                "print('mock-output-' + str(attempt), flush=True)\n"
                "print('mock-warning-' + str(attempt), file=sys.stderr, flush=True)\n"
                "exits = json.loads(os.environ['PERANT_TEST_EXITS'])\n"
                "sys.exit(exits[attempt - 1] if attempt <= len(exits) else 98)\n",
                encoding="utf-8",
            )
            original = self.commands[app]
            self.assertEqual(original.count(OFFICE_EXECUTABLE), 1)
            mock_command = original.replace(
                OFFICE_EXECUTABLE,
                shlex.quote(sys.executable) + " " + shlex.quote(str(child)),
            )
            generated = self.generate(mock_command)
            self.assertEqual(generated.count("cd /workspace || exit 1\n"), 1)
            # Only adapt the guest's absolute working directory for this host
            # fixture. The production retry loop and argument forwarding run as-is.
            generated = generated.replace(
                "cd /workspace || exit 1\n",
                "cd " + shlex.quote(str(workspace)) + " || exit 1\n",
            )
            launcher = workspace / "launch office.sh"
            launcher.write_text(generated, encoding="utf-8")
            marker = workspace / "must-not-be-created"
            extra_args = [
                "reference 会议.odt", "quote'and\"double",
                "literal;$(touch " + shlex.quote(str(marker)) + ")",
            ]
            environment = dict(os.environ)
            environment.update({
                "PERANT_TEST_CALLS": str(calls),
                "PERANT_TEST_EXITS": json.dumps(exits),
                "PERANT_TEST_SENTINEL": "same environment 🐜",
            })
            result = subprocess.run(
                ["/bin/sh", str(launcher), *extra_args], env=environment,
                capture_output=True, text=True, check=False, timeout=10,
            )
            self.assertEqual(result.returncode, expected_status, result.stderr)
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len(records), expected_launches)
            command_parts = shlex.split(original)
            expected_args = command_parts[command_parts.index(OFFICE_EXECUTABLE) + 1:] + extra_args
            for record in records:
                self.assertEqual(record["argv"], expected_args)
                self.assertEqual(record["cwd"], str(workspace))
                self.assertEqual(record["locking"], "1")
                self.assertEqual(record["plugin"], "gtk3")
                self.assertEqual(record["sentinel"], "same environment 🐜")
                self.assertEqual(record["environmentHash"], records[0]["environmentHash"])
            self.assertFalse(marker.exists())
            self.assertEqual(
                result.stdout,
                "".join(f"mock-output-{attempt}\n" for attempt in range(1, expected_launches + 1)),
            )
            warnings = [line for line in result.stderr.splitlines()
                        if line.startswith("mock-warning-")]
            self.assertEqual(
                warnings,
                [f"mock-warning-{attempt}" for attempt in range(1, expected_launches + 1)],
            )


if __name__ == "__main__":
    unittest.main()
