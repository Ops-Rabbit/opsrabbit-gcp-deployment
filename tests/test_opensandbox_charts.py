"""Verify the pinned upstream chart contract used by the installer."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).parents[1]
VENDOR = ROOT / "charts/vendor"


class OpenSandboxCharts(unittest.TestCase):
    def test_vendored_sources_match_pinned_manifest(self):
        entries = json.loads((VENDOR / "source-sha256.json").read_text())
        sources = {str(p.relative_to(VENDOR)) for directory in VENDOR.iterdir() if directory.is_dir() for p in directory.rglob("*") if p.is_file()}
        self.assertEqual(set(entries), sources)
        self.assertEqual(len(list(VENDOR.glob("*/Chart.yaml"))), 4)
        for filename, digest in entries.items():
            self.assertEqual(hashlib.sha256((VENDOR / filename).read_bytes()).hexdigest(), digest)

    @unittest.skipUnless(shutil.which("helm"), "helm required")
    def test_server_and_gateway_render_private_services_and_secret_references(self):
        fixtures = [
            ("opensandbox-server", "server", "opensandbox-server", {
                "service": {"type": "ClusterIP"},
                "env": [{"name": "OPENSANDBOX_SERVER_API_KEY", "valueFrom": {"secretKeyRef": {"name": "api", "key": "api-key"}}}],
                "gateway": {"enabled": True, "host": "opensandbox-ingress-gateway.test-system.svc", "gatewayRouteMode": "header", "secureAccess": {"existingSecret": "signing"}},
            }),
            ("ingress-gateway", "gateway", "opensandbox-ingress-gateway", {
                "service": {"type": "ClusterIP"}, "secureAccess": {"existingSecret": "signing"},
            }),
        ]
        for chart, component, name, overrides in fixtures:
            image = {"repository": "us-central1-docker.pkg.dev/test-project/opsrabbit/" + component, "tag": "release-1.1.1@sha256:" + "a" * 64}
            values = {"namespaceOverride": "test-system", "fullnameOverride": name, component: {"image": image, **overrides}}
            result = subprocess.run(["helm", "template", "opsrabbit-test", str(VENDOR / chart), "--namespace", "test-system", "-f", "-"], input=json.dumps(values), capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            rendered = result.stdout
            services = [doc for doc in rendered.split("---") if "kind: Service\n" in doc]
            self.assertEqual(len(services), 1)
            self.assertIn("name: " + name, services[0])
            self.assertIn("type: ClusterIP", services[0])
            self.assertNotIn("kind: Secret\n", rendered)
            self.assertIn("secretKeyRef:", rendered)
            self.assertIn("name: \"signing\"", rendered)
            self.assertIn(image["repository"] + ":" + image["tag"], rendered)


if __name__ == "__main__":
    unittest.main()
