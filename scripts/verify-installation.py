#!/usr/bin/env python3
"""Verify a customer endpoint using normal DNS and certificate validation."""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check_endpoint(origin, verify_http_redirect=True):
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme != "https" or not parsed.hostname or parsed.path or parsed.query or parsed.fragment or parsed.username:
        raise ValueError("The application URL must be an HTTPS origin without credentials, path, query or fragment")
    opener = urllib.request.build_opener(NoRedirect())
    with opener.open(origin + "/", timeout=20) as response:
        if response.status != 200 or "text/html" not in response.headers.get("Content-Type", ""):
            raise ValueError("The application root did not return the web UI")
    with opener.open(origin + "/api/health", timeout=20) as response:
        if response.status != 200 or "application/json" not in response.headers.get("Content-Type", ""):
            raise ValueError("The backend health endpoint did not return JSON")
        health = json.loads(response.read(65536))
        if not isinstance(health, dict) or health.get("ok") is not True:
            raise ValueError("The backend did not report ok=true")
    # Native Cloud Run provides its own HTTPS endpoint; custom domains must
    # have the installer's redirect listener as well.
    if verify_http_redirect and not parsed.hostname.endswith(".run.app"):
        try:
            with opener.open("http://" + parsed.netloc + "/", timeout=20):
                raise ValueError("HTTP must redirect to HTTPS")
        except urllib.error.HTTPError as error:
            try:
                if error.code not in (301, 308) or error.headers.get("Location") != origin + "/":
                    raise ValueError("HTTP did not redirect to the canonical HTTPS origin") from error
            finally:
                error.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="Defaults to the URL in terraform output -json installation")
    parser.add_argument("--private", action="store_true", help="Use with --url for an internal HTTPS endpoint without an HTTP listener")
    parser.add_argument("--timeout", type=int, default=1800, help="Seconds to wait for DNS, certificate and load-balancer readiness")
    args = parser.parse_args()
    if args.timeout < 0:
        parser.error("--timeout must be nonnegative")
    origin = args.url
    verify_http_redirect = not args.private
    if not origin:
        result = subprocess.run(["terraform", "output", "-json", "installation"], text=True, capture_output=True)
        if result.returncode:
            print("Cannot read opsrabbit_url. Run from the initialized installation directory after apply.", file=sys.stderr)
            return 1
        try:
            metadata = json.loads(result.stdout)
            origin = metadata["url"]
            verify_http_redirect = metadata["verify_http_redirect"]
        except (ValueError, KeyError, TypeError):
            print("Invalid installation output. Apply the current installer configuration first.", file=sys.stderr)
            return 1
    if not origin:
        print("Application installation is disabled; bootstrap infrastructure is not a ready installation.", file=sys.stderr)
        return 1
    deadline = time.monotonic() + args.timeout
    while True:
        try:
            check_endpoint(origin, verify_http_redirect)
            print(f"Endpoint ready: {origin} (TLS, UI, backend health and applicable redirect verified)")
            print("Complete the first administrator setup in the browser; login and application workflows require acceptance testing.")
            return 0
        except (ValueError, OSError, urllib.error.URLError) as error:
            if time.monotonic() >= deadline:
                print(f"Endpoint is not ready: {error}", file=sys.stderr)
                return 1
            print(f"Waiting for endpoint readiness: {error}", file=sys.stderr, flush=True)
            time.sleep(min(15, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    sys.exit(main())
