import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "opsrabbit"
HELM = shutil.which("helm")
BACKEND = "gcr.io/distroless/static-debian12@sha256:" + "a" * 64
WEB = "gcr.io/distroless/static-debian12@sha256:" + "b" * 64


@unittest.skipUnless(HELM, "helm is required for chart tests")
class HelmChartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.values = [
            "--set",
            f"image.backend={BACKEND}",
            "--set",
            f"image.web={WEB}",
            "--set",
            "secrets.existingSecret=opsrabbit-runtime",
        ]
        result = subprocess.run(
            [HELM, "template", "opsrabbit", str(CHART), "--namespace", "opsrabbit", *cls.values],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            raise AssertionError(result.stderr)
        cls.rendered = result.stdout

    def test_rendered_workloads_and_services(self):
        self.assertEqual(self.rendered.count("kind: Deployment\n"), 2)
        self.assertEqual(self.rendered.count("kind: Service\n"), 2)
        self.assertIn("kind: PersistentVolumeClaim", self.rendered)

    def test_rendered_workloads_have_security_and_health_defaults(self):
        self.assertEqual(self.rendered.count("runAsNonRoot: true"), 2)
        self.assertEqual(self.rendered.count("runAsUser: 10001"), 2)
        self.assertEqual(self.rendered.count("readOnlyRootFilesystem: true"), 2)
        self.assertEqual(self.rendered.count("allowPrivilegeEscalation: false"), 2)
        self.assertEqual(self.rendered.count("path: /health"), 3)
        self.assertNotIn("privileged: true", self.rendered)
        self.assertNotIn("hostNetwork: true", self.rendered)

    def test_rendered_workloads_use_secret_references(self):
        self.assertEqual(self.rendered.count("secretKeyRef:"), 3)
        self.assertIn("key: DATABASE_URL", self.rendered)
        self.assertIn("key: BETTER_AUTH_SECRET", self.rendered)
        self.assertIn("key: OPSRABBIT_NODE_ENCRYPTION_KEY", self.rendered)

    def test_images_are_required(self):
        result = subprocess.run(
            [HELM, "template", "opsrabbit", str(CHART), "--namespace", "opsrabbit"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image.backend is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
