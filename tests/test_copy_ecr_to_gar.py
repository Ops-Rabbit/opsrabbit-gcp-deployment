"""Offline contract checks for the ECR-to-GAR image handoff."""

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
DIGEST = "sha256:" + "a" * 64
STUB = """#!/usr/bin/env python3
import os
import pathlib
import sys

tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a', encoding='utf-8') as log:
    log.write(tool + ' ' + ' '.join(args) + '\\n')

if tool == 'aws':
    if args[:2] == ['ecr', 'get-login-password']:
        print('test-token')
    elif args[:2] == ['ecr', 'describe-images']:
        print(os.environ['TEST_DIGEST'])
    else:
        print('{}')
elif tool == 'gcloud':
    if args[:2] == ['artifacts', 'repositories'] and 'list' in args:
        if os.environ['REPO_EXISTS'] == '1':
            print('projects/test-project/locations/us-central1/repositories/opsrabbit')
    elif args[:2] == ['artifacts', 'repositories'] and 'describe' in args:
        print('DOCKER')
    elif args[:3] == ['artifacts', 'docker', 'images']:
        print(os.environ['TEST_DIGEST'])
    elif args[:2] == ['auth', 'print-access-token']:
        print('test-token')
    elif args[:2] == ['projects', 'describe']:
        print('test-project')
elif tool == 'crane':
    if args[:2] == ['auth', 'login']:
        sys.stdin.read()
    elif args[0] == 'config':
        print('{"os":"linux","architecture":"amd64"}')
    elif args[0] == 'digest':
        print(os.environ['TEST_DIGEST'])
"""


class ImageCopyTests(unittest.TestCase):
    def run_copy(self, repo_exists: bool) -> str:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name in ("aws", "gcloud", "crane"):
                stub = root / name
                stub.write_text(STUB, encoding="utf-8")
                stub.chmod(0o700)
            log = root / "calls.log"
            env = os.environ.copy()
            env.update({
                "PATH": str(root) + os.pathsep + env["PATH"],
                "MOCK_LOG": str(log),
                "REPO_EXISTS": "1" if repo_exists else "0",
                "TEST_DIGEST": DIGEST,
                "ECR_ACCOUNT_ID": "123456789012",
                "PROJECT_ID": "test-project",
                "BACKEND_DIGEST": DIGEST,
                "WEB_DIGEST": DIGEST,
            })
            result = subprocess.run(
                ["bash", str(ROOT / "scripts" / "copy-ecr-to-gar.sh")],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return log.read_text(encoding="utf-8")

    def test_existing_repository_is_reused(self):
        calls = self.run_copy(repo_exists=True)
        self.assertNotIn("gcloud artifacts repositories create", calls)
        self.assertEqual(calls.count("crane cp "), 2)

    def test_missing_repository_is_created_once(self):
        calls = self.run_copy(repo_exists=False)
        self.assertEqual(calls.count("gcloud artifacts repositories create"), 1)
        self.assertEqual(calls.count("crane cp "), 2)


if __name__ == "__main__":
    unittest.main()
