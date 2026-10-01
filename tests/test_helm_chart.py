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

    def render(self, *extra_values):
        result = subprocess.run(
            [HELM, "template", "opsrabbit", str(CHART), "--namespace", "opsrabbit", *self.values, *extra_values],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_rendered_workloads_and_services(self):
        self.assertEqual(self.rendered.count("kind: Deployment\n"), 2)
        self.assertEqual(self.rendered.count("kind: Service\n"), 2)
        self.assertIn("kind: PersistentVolumeClaim", self.rendered)

    def test_rendered_workloads_have_security_and_health_defaults(self):
        self.assertEqual(self.rendered.count("runAsNonRoot: true"), 2)
        self.assertEqual(self.rendered.count("runAsUser: 10001"), 2)
        self.assertEqual(self.rendered.count("readOnlyRootFilesystem: true"), 3)
        self.assertEqual(self.rendered.count("allowPrivilegeEscalation: false"), 3)
        self.assertEqual(self.rendered.count("path: /health"), 3)
        self.assertNotIn("privileged: true", self.rendered)
        self.assertNotIn("hostNetwork: true", self.rendered)

    def test_rendered_workloads_use_secret_references(self):
        self.assertEqual(self.rendered.count("secretKeyRef:"), 4)
        self.assertIn("key: DATABASE_URL", self.rendered)
        self.assertIn("key: BETTER_AUTH_SECRET", self.rendered)
        self.assertIn("key: OPSRABBIT_NODE_ENCRYPTION_KEY", self.rendered)
        self.assertIn("name: OPSRABBIT_NODE_DATABASE_URL", self.rendered)
        self.assertIn("name: WEB_API_UPSTREAM", self.rendered)

    def test_inline_secret_values_create_a_secret(self):
        rendered = self.render(
            "--set",
            "secrets.existingSecret=",
            "--set",
            "secrets.databaseUrl=postgresql://db",
            "--set",
            "secrets.betterAuthSecret=test-auth",
            "--set",
            "secrets.encryptionKey=test-encryption",
        )
        self.assertIn("kind: Secret\n", rendered)
        self.assertIn("DATABASE_URL: \"postgresql://db\"", rendered)

    def test_service_annotations_are_metadata_annotations(self):
        rendered = self.render("--set", "service.annotations.test=ok")
        self.assertEqual(rendered.count("test: ok"), 2)
        self.assertNotIn("spec:\n  type: ClusterIP\n  annotations:", rendered)

    def test_images_are_required(self):
        result = subprocess.run(
            [HELM, "template", "opsrabbit", str(CHART), "--namespace", "opsrabbit"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image.backend is required", result.stderr)

    def test_backend_stays_internal_when_web_is_exposed(self):
        rendered = self.render("--set", "service.type=LoadBalancer")
        services = [doc for doc in rendered.split("---") if "kind: Service\n" in doc]
        backend = next(doc for doc in services if "component: backend" in doc)
        web = next(doc for doc in services if "component: web" in doc)
        self.assertIn("type: ClusterIP", backend)
        self.assertIn("type: LoadBalancer", web)

    def test_gke_endpoint_routes_only_to_web_and_checks_api(self):
        rendered = self.render(
            "--set", "ingress.enabled=true",
            "--set", "gkeEndpoint.enabled=true",
            "--set", "gkeEndpoint.staticIpName=application-ip",
            "--set", "gkeEndpoint.certificateNames=application-cert",
            "--set", "gkeEndpoint.sslPolicy=application-tls",
            "--set", "service.type=LoadBalancer",
        )
        self.assertIn("kubernetes.io/ingress.class: gce", rendered)
        self.assertIn('ingress.gcp.kubernetes.io/pre-shared-cert: "application-cert"', rendered)
        self.assertIn('kubernetes.io/ingress.global-static-ip-name: "application-ip"', rendered)
        self.assertIn("kind: FrontendConfig", rendered)
        self.assertIn("redirectToHttps:\n    enabled: true", rendered)
        self.assertIn("requestPath: /api/health", rendered)
        self.assertIn("timeoutSec: 3600", rendered)
        services = [doc for doc in rendered.split("---") if "kind: Service\n" in doc]
        self.assertTrue(all("type: ClusterIP" in doc for doc in services))
        backend = next(doc for doc in services if "component: backend" in doc)
        self.assertNotIn("cloud.google.com/neg", backend)
        ingress = next(doc for doc in rendered.split("---") if "kind: Ingress\n" in doc)
        self.assertIn("name: opsrabbit-opsrabbit-web", ingress)
        self.assertNotIn("name: opsrabbit-opsrabbit-backend", ingress)


if __name__ == "__main__":
    unittest.main()
