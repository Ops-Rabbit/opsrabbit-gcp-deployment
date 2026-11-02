#!/usr/bin/env python3
"""Prepare private Kubernetes credentials and initialize OpsRabbit via stdin."""

import argparse
import base64
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile


def kubectl(context, args, payload=None, timeout=180):
    result = subprocess.run(
        ["kubectl", *(["--context", context] if context else []), "--request-timeout=0" if args and args[0] == "exec" else "--request-timeout=30s", *args],
        input=payload, text=True, capture_output=True, timeout=timeout,
        check=False,
    )
    if result.returncode:
        # Kubernetes errors can repeat submitted Secret contents.
        raise RuntimeError("Kubernetes operation failed; check context, permissions and workload readiness.")
    return result.stdout


def ensure_namespace(context, namespace):
    existing = kubectl(context, ["get", "namespace", namespace, "--ignore-not-found", "-o", "name"])
    if not existing.strip():
        kubectl(context, ["create", "namespace", namespace])


def ensure_secret(context, namespace, name, data):
    existing = kubectl(context, ["get", "secret", name, "-n", namespace, "--ignore-not-found", "-o", "json"])
    if existing.strip():
        stored = json.loads(existing).get("data", {})
        if not all(stored.get(key) for key in data):
            raise RuntimeError("Existing sandbox Secret is incomplete; repair it explicitly before retrying.")
        return
    resource = {
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {"name": name, "namespace": namespace},
        "stringData": data,
    }
    kubectl(context, ["create", "-f", "-"], json.dumps(resource))


def prepare(args):
    ensure_namespace(args.context, args.namespace)
    ensure_namespace(args.context, args.workload_namespace)
    ensure_secret(args.context, args.namespace, args.api_secret, {"api-key": secrets.token_urlsafe(48)})
    signing_key = base64.b64encode(secrets.token_bytes(32)).decode("ascii")
    ensure_secret(args.context, args.namespace, args.signing_secret, {"keys": "a=" + signing_key, "active-key": "a"})


def configure(args):
    if not args.deployment and args.release:
        deployments = json.loads(kubectl(args.context, ["get", "deployments", "-n", args.app_namespace, "-l", "app.kubernetes.io/instance=" + args.release + ",app.kubernetes.io/component=backend", "-o", "json"]))["items"]
        if len(deployments) != 1:
            raise RuntimeError("Expected exactly one backend Deployment for this Helm release.")
        args.deployment = deployments[0]["metadata"]["name"]
    if not args.deployment or not args.image:
        raise RuntimeError("Configuration requires an exact backend deployment and immutable sandbox image.")
    if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", args.image):
        raise RuntimeError("Sandbox image must use an immutable SHA-256 digest.")
    raw = json.loads(kubectl(args.context, ["get", "secret", args.api_secret, "-n", args.namespace, "-o", "json"]))
    key = base64.b64decode(raw["data"]["api-key"], validate=True).decode("utf-8")
    endpoint = "http://opensandbox-server." + args.namespace + ".svc"
    # Check from the backend's network without exposing the API key in argv.
    probe = "const c=JSON.parse(await new Promise(r=>{let s='';process.stdin.on('data',x=>s+=x);process.stdin.on('end',()=>r(s))}));const r=await fetch(c.endpoint+'/v1/sandboxes',{headers:{'OPEN-SANDBOX-API-KEY':c.apiKey},signal:AbortSignal.timeout(15000),redirect:'error'});if(!r.ok)process.exit(1);"
    target = ["exec", "-i", "-n", args.app_namespace, "deployment/" + args.deployment, "-c", "backend", "--"]
    capabilities = json.loads(kubectl(args.context, [*target, "node", "/opt/opsrabbit/apps/backend/dist/scripts/initialize-opensandbox.js", "--capabilities"]))
    if capabilities.get("contractVersion") != 1 or capabilities.get("activation") is not True or capabilities.get("verification") is not True:
        raise RuntimeError("Backend does not support installer activation; install a compatible product release.")
    kubectl(args.context, [*target, "node", "--input-type=module", "-e", probe], json.dumps({"endpoint": endpoint, "apiKey": key}))
    verified = kubectl(args.context, [*target, "node", "/opt/opsrabbit/apps/backend/dist/scripts/initialize-opensandbox.js", "--verify"], json.dumps({"endpoint": endpoint, "apiKey": key, "image": args.image}), timeout=720)
    if "Existing sandbox configuration preserved." in verified:
        print("Existing sandbox settings preserved; supplied settings were not applied. Verify runtime configuration before claiming readiness.")
        return
    if "Sandbox execution and cleanup verified." not in verified:
        raise RuntimeError("Sandbox execution verification did not succeed; product settings were not initialized.")
    result = kubectl(args.context, [*target, "node", "/opt/opsrabbit/apps/backend/dist/scripts/initialize-opensandbox.js"], json.dumps({"endpoint": endpoint, "apiKey": key, "image": args.image, "activate": True}))
    if "Existing sandbox configuration preserved." in result:
        print("Existing sandbox settings preserved; supplied settings were not applied. Verify runtime configuration before claiming readiness.")
        return
    if "Sandbox configuration initialized; execution enabled." not in result:
        raise RuntimeError("Backend does not confirm activation; install a compatible product release.")
    print("OpenSandbox configuration initialized. Product execution checks are still required.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "configure"])
    parser.add_argument("--context")
    parser.add_argument("--project")
    parser.add_argument("--cluster")
    parser.add_argument("--location")
    parser.add_argument("--namespace", default="opensandbox-system")
    parser.add_argument("--workload-namespace", default="opensandbox")
    parser.add_argument("--app-namespace", default="opsrabbit")
    parser.add_argument("--api-secret", default="opensandbox-api-key")
    parser.add_argument("--signing-secret", default="opensandbox-signing-key")
    parser.add_argument("--deployment")
    parser.add_argument("--release")
    parser.add_argument("--image")
    args = parser.parse_args()
    try:
        if args.context:
            (prepare if args.action == "prepare" else configure)(args)
        else:
            if not all([args.project, args.cluster, args.location]):
                raise RuntimeError("Supply an explicit context or project, cluster and location.")
            with tempfile.TemporaryDirectory(prefix="opsrabbit-kube-") as directory:
                previous = os.environ.get("KUBECONFIG")
                os.environ["KUBECONFIG"] = os.path.join(directory, "config")
                try:
                    result = subprocess.run(["gcloud", "container", "clusters", "get-credentials", args.cluster, "--project", args.project, "--location", args.location], capture_output=True, text=True, timeout=120, check=False)
                    if result.returncode:
                        raise RuntimeError("Cannot obtain credentials for the specified GKE cluster.")
                    args.context = kubectl("", ["config", "current-context"]).strip()
                    (prepare if args.action == "prepare" else configure)(args)
                finally:
                    if previous is None:
                        os.environ.pop("KUBECONFIG", None)
                    else:
                        os.environ["KUBECONFIG"] = previous
    except (RuntimeError, ValueError, KeyError, subprocess.SubprocessError, OSError) as error:
        print(str(error) if isinstance(error, RuntimeError) else "Sandbox bootstrap failed; no sensitive diagnostics were printed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
