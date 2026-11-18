"""Run the production Filestore initializer against disposable filesystem fixtures."""
import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTIVE_DIRECTORIES = {"application-data", "git-workspace", "agent-browser"}


class FilestoreInitTests(unittest.TestCase):
    def initialize(self, share):
        source = (ROOT / "filestore-init.tf").read_text()
        match = re.search(r'args\s*=\s*\[\s*("(?:[^"\\]|\\.)*")', source)
        self.assertIsNotNone(match, "Filestore job must supply its initialization command")
        command = json.loads(match.group(1))
        command = command.replace("/mnt/share", str(share))
        command = command.replace("${var.backend_uid}", str(os.getuid()))
        command = command.replace("${var.backend_gid}", str(os.getgid()))
        subprocess.run(["sh", "-c", command], check=True, capture_output=True, text=True, timeout=120)

    def test_fresh_share_creates_only_active_directories(self):
        with tempfile.TemporaryDirectory(prefix="opsrabbit-fs-init-") as directory:
            share = pathlib.Path(directory)
            self.initialize(share)
            self.assertEqual({entry.name for entry in share.iterdir()}, ACTIVE_DIRECTORIES)
            self.assertTrue(all((share / name).is_dir() for name in ACTIVE_DIRECTORIES))

    def test_existing_legacy_and_active_files_are_preserved(self):
        with tempfile.TemporaryDirectory(prefix="opsrabbit-fs-init-") as directory:
            share = pathlib.Path(directory)
            expected = {
                "codex/legacy-state.bin": b"legacy-state\x00keep",
                "application-data/existing.bin": b"application-data\x00keep",
                "git-workspace/repository/README": b"working files\n",
                "agent-browser/profile/state": b"browser state\n",
            }
            for relative, content in expected.items():
                path = share / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            self.initialize(share)
            self.initialize(share)
            self.assertEqual({entry.name for entry in share.iterdir()}, ACTIVE_DIRECTORIES | {"codex"})
            self.assertEqual(
                {str(path.relative_to(share)): path.read_bytes() for path in share.rglob("*") if path.is_file()},
                expected,
            )


if __name__ == "__main__":
    unittest.main()
