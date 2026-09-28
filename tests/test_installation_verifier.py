import importlib.util
import io
import pathlib
import unittest
import urllib.error
from unittest.mock import patch


PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "verify-installation.py"
SPEC = importlib.util.spec_from_file_location("installation_verifier", PATH)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class Response(io.BytesIO):
    def __init__(self, body, content_type, status=200):
        super().__init__(body)
        self.headers = {"Content-Type": content_type}
        self.status = status


class InstallationVerifierTests(unittest.TestCase):
    def check(self, responses, **kwargs):
        with patch.object(VERIFIER.urllib.request, "build_opener") as build:
            build.return_value.open.side_effect = responses
            VERIFIER.check_endpoint("https://opsrabbit.example.com", **kwargs)
            return build.return_value.open.call_count

    @staticmethod
    def ui():
        return Response(b"<html>OpsRabbit</html>", "text/html")

    @staticmethod
    def health():
        return Response(b'{"ok":true}', "application/json")

    @staticmethod
    def redirect(location="https://opsrabbit.example.com/"):
        return urllib.error.HTTPError("http://opsrabbit.example.com/", 301, "redirect", {"Location": location}, None)

    def test_public_endpoint_requires_all_checks(self):
        self.assertEqual(self.check([self.ui(), self.health(), self.redirect()]), 3)

    def test_spa_fallback_does_not_pass_as_backend_health(self):
        with self.assertRaisesRegex(ValueError, "did not return JSON"):
            self.check([self.ui(), self.ui()])

    def test_backend_must_explicitly_report_healthy(self):
        for body in (b'{"ok":false}', b'{"ok":"true"}', b'[]'):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "ok=true"):
                self.check([self.ui(), Response(body, "application/json")])

    def test_certificate_failures_are_not_ignored(self):
        with self.assertRaises(urllib.error.URLError):
            self.check([urllib.error.URLError("certificate verify failed")])

    def test_wrong_redirect_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "canonical"):
            self.check([self.ui(), self.health(), self.redirect("https://elsewhere.example.com/")])

    def test_plaintext_application_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "must redirect"):
            self.check([self.ui(), self.health(), self.ui()])

    def test_private_endpoint_does_not_require_http_listener(self):
        self.assertEqual(self.check([self.ui(), self.health()], verify_http_redirect=False), 2)

    def test_unsafe_origins_are_rejected(self):
        for url in ("http://example.com", "https://user:password@example.com", "https://example.com/api"):
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "HTTPS origin"):
                VERIFIER.check_endpoint(url)


if __name__ == "__main__":
    unittest.main()
