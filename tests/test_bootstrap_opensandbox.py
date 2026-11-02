"""Exercise bootstrap safety boundaries without credentials or a live cluster."""
import importlib.util
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("bootstrap", Path(__file__).parents[1] / "scripts/bootstrap-opensandbox.py")
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def configure_args(self):
        return SimpleNamespace(deployment="test-backend", image="image@sha256:" + "a" * 64, context="test-context", namespace="sandbox", app_namespace="app", api_secret="api")

    def test_fresh_activation_keeps_key_off_argv_and_output(self):
        with patch.object(bootstrap, "kubectl", side_effect=[
            '{"data":{"api-key":"Zml4dHVyZQ=="}}',
            '{"activation":true,"verification":true,"contractVersion":1}', "",
            "Sandbox execution and cleanup verified.\n",
            "Sandbox configuration initialized; execution enabled.\n",
        ]) as call, patch("sys.stdout", new_callable=io.StringIO) as output:
            bootstrap.configure(self.configure_args())
            self.assertIn("initialized", output.getvalue())
            self.assertNotIn("fixture", output.getvalue())
            for operation in call.call_args_list:
                self.assertNotIn("fixture", str(operation.args[:2]))
            payload = json.loads(call.call_args.args[2])
            self.assertEqual(payload["apiKey"], "fixture")
            self.assertTrue(payload["activate"])

    def test_existing_settings_are_not_reported_as_new_activation(self):
        with patch.object(bootstrap, "kubectl", side_effect=[
            '{"data":{"api-key":"Zml4dHVyZQ=="}}',
            '{"activation":true,"verification":true,"contractVersion":1}', "",
            "Existing sandbox configuration preserved.\n",
        ]) as call, patch("sys.stdout", new_callable=io.StringIO) as output:
            bootstrap.configure(self.configure_args())
            self.assertIn("not applied", output.getvalue())
            self.assertNotIn("configuration initialized", output.getvalue())
            # A reset after preservation must not turn an unverified skip into activation.
            self.assertEqual(call.call_count, 4)
            self.assertIn("--verify", call.call_args.args[1])

    def test_failed_authenticated_probe_never_initializes(self):
        with patch.object(bootstrap, "kubectl", side_effect=[
            '{"data":{"api-key":"Zml4dHVyZQ=="}}',
            '{"activation":true,"verification":true,"contractVersion":1}', RuntimeError("Probe failed"),
        ]) as call:
            with self.assertRaisesRegex(RuntimeError, "Probe failed"):
                bootstrap.configure(self.configure_args())
            self.assertEqual(call.call_count, 3)

    def test_unusable_image_never_initializes_settings(self):
        with patch.object(bootstrap, "kubectl", side_effect=[
            '{"data":{"api-key":"Zml4dHVyZQ=="}}',
            '{"activation":true,"verification":true,"contractVersion":1}', "",
            RuntimeError("Runtime verification failed"),
        ]) as call:
            with self.assertRaisesRegex(RuntimeError, "Runtime verification failed"):
                bootstrap.configure(self.configure_args())
            self.assertEqual(call.call_count, 4)
            self.assertIn("--verify", call.call_args.args[1])
            self.assertEqual(call.call_args.kwargs["timeout"], 720)

    def test_gcloud_uses_temporary_kubeconfig_and_restores_environment(self):
        seen = []
        def gcloud(*args, **kwargs):
            seen.append(os.environ["KUBECONFIG"])
            return SimpleNamespace(returncode=0)
        with patch.dict(os.environ, {"KUBECONFIG": "/original/config"}), patch("sys.argv", ["bootstrap", "prepare", "--project", "p", "--cluster", "c", "--location", "r"]), patch.object(bootstrap.subprocess, "run", side_effect=gcloud), patch.object(bootstrap, "kubectl", return_value="gke_p_r_c"), patch.object(bootstrap, "prepare") as prepare:
            self.assertEqual(bootstrap.main(), 0)
            self.assertEqual(os.environ["KUBECONFIG"], "/original/config")
            self.assertEqual(prepare.call_args.args[0].context, "gke_p_r_c")
        self.assertNotEqual(seen[0], "/original/config")
        self.assertFalse(Path(seen[0]).parent.exists())

    def test_existing_secret_is_preserved(self):
        with patch.object(bootstrap, "kubectl", return_value=json.dumps({"data": {"api-key": "Zml4dHVyZQ=="}})) as call:
            bootstrap.ensure_secret("test-context", "test-ns", "test-secret", {"api-key": "unused"})
            self.assertEqual(call.call_count, 1)

    def test_missing_secret_uses_stdin(self):
        with patch.object(bootstrap, "kubectl", side_effect=["", "created"]) as call:
            bootstrap.ensure_secret("test-context", "test-ns", "test-secret", {"api-key": "fixture-only"})
            args = call.call_args.args
            self.assertEqual(args[1], ["create", "-f", "-"])
            self.assertEqual(json.loads(args[2])["stringData"], {"api-key": "fixture-only"})

    def test_incomplete_secret_fails_without_replacing(self):
        with patch.object(bootstrap, "kubectl", return_value='{"data":{}}') as call:
            with self.assertRaisesRegex(RuntimeError, "incomplete"):
                bootstrap.ensure_secret("test-context", "test-ns", "test-secret", {"api-key": "unused"})
            self.assertEqual(call.call_count, 1)

    def test_kubernetes_error_does_not_echo_sensitive_payload(self):
        with patch.object(bootstrap.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="fixture-secret", stderr="fixture-secret")):
            with self.assertRaises(RuntimeError) as result:
                bootstrap.kubectl("test-context", ["create", "-f", "-"], "fixture-secret")
            self.assertNotIn("fixture-secret", str(result.exception))

    def test_tag_only_image_rejected_before_cluster_access(self):
        args = SimpleNamespace(deployment="test-backend", image="image:latest")
        with patch.object(bootstrap, "kubectl") as call:
            with self.assertRaisesRegex(RuntimeError, "immutable"):
                bootstrap.configure(args)
            call.assert_not_called()

    def test_older_backend_cannot_silently_initialize_disabled(self):
        args = SimpleNamespace(deployment="test-backend", image="image@sha256:" + "a" * 64, context="test-context", namespace="sandbox", app_namespace="app", api_secret="api")
        with patch.object(bootstrap, "kubectl", side_effect=['{"data":{"api-key":"Zml4dHVyZQ=="}}', '{"activation":false,"contractVersion":1}']) as call:
            with self.assertRaisesRegex(RuntimeError, "does not support"):
                bootstrap.configure(args)
            self.assertEqual(call.call_count, 2)


if __name__ == "__main__":
    unittest.main()
