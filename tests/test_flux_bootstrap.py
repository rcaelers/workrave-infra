"""Exercise bootstrap failures without contacting a cluster or GitHub.

Run: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["BOOTSTRAP_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args,
                          "git_password_set": bool(os.environ.get("GIT_PASSWORD"))}) + "\n")
if tool == "gh" and args == ["auth", "token"]:
    print("test-github-token")
if tool == "sops":
    if os.environ.get("BAD_KEY"):
        sys.exit(1)
    print("decrypted-credential-must-not-appear-in-output")
if tool == "kubectl":
    assert args.pop(0) == "--context=disposable", args
    if args[:2] == ["get", "nodes"]:
        print(os.environ.get("NODE_ARCH", "amd64 "))
    if args[:2] == ["get", "deployment"] and os.environ.get("TRAEFIK"):
        print("deployment.apps/traefik")
    if args[:2] == ["get", "helmchart"] and os.environ.get("TRAEFIK_CHART"):
        print("helmchart.helm.cattle.io/traefik")
    if args[:2] == ["get", "crd"]:
        print(os.environ.get("GATEWAY_BUNDLE", "v1.6.1 standard"))
    if args[:2] == ["get", "secret"] and os.environ.get("MISSING_KEY"):
        sys.exit(1)
    if args[0] == "create":
        print("apiVersion: v1\nkind: Secret\nmetadata:\n  name: dummy")
    if args[0] == "apply":
        sys.stdin.read()
    if args[:2] == ["wait", "kustomizations.kustomize.toolkit.fluxcd.io"] and os.environ.get("FAILED_TIER"):
        sys.exit(1)
    if args[:2] == ["wait", "helmreleases.helm.toolkit.fluxcd.io"] and os.environ.get("FAILED_HELM"):
        sys.exit(1)
    if args[0] == "rollout" and os.environ.get("FAILED_PROXY"):
        sys.exit(1)
'''


class FluxBootstrapTest(unittest.TestCase):
    def run_bootstrap(self, flags=None, with_key=False, environment="production"):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for tool in ("flux", "kubectl", "gh", "sops"):
                executable = directory / tool
                executable.write_text(MOCK)
                executable.chmod(0o755)
            log = directory / "calls.jsonl"
            env = os.environ.copy()
            env.pop("GIT_PASSWORD", None)
            env.update({"PATH": f'{directory}:{env["PATH"]}',
                        "BOOTSTRAP_TEST_LOG": str(log)})
            env.update(flags or {})
            args = ["bash", str(ROOT / "scripts/flux-bootstrap.sh"), environment, "disposable"]
            if with_key:
                key = directory / "original-age-key.txt"
                key.write_text("dummy key handled only by mocked sops")
                args.append(str(key))
            result = subprocess.run(args, env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def assert_no_bootstrap(self, result, calls):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c["tool"] == "flux" and c["args"][:2] == ["bootstrap", "git"] for c in calls))

    def test_missing_original_key_stops_before_install(self):
        result, calls = self.run_bootstrap({"MISSING_KEY": "1"})
        self.assert_no_bootstrap(result, calls)
        self.assertIn("original SOPS age key is required", result.stderr)

    def test_incompatible_gateway_api_stops_before_install(self):
        for bundle in ("", "v1.5.1 standard", "v1.6.1 experimental"):
            with self.subTest(bundle=bundle):
                result, calls = self.run_bootstrap({"GATEWAY_BUNDLE": bundle})
                self.assert_no_bootstrap(result, calls)

    def test_traefik_or_its_pending_chart_stops_before_install(self):
        for flag in ("TRAEFIK", "TRAEFIK_CHART"):
            with self.subTest(flag=flag):
                result, calls = self.run_bootstrap({flag: "1"})
                self.assert_no_bootstrap(result, calls)

    def test_unsupported_node_architecture_stops_before_install(self):
        result, calls = self.run_bootstrap({"NODE_ARCH": "arm64 "})
        self.assert_no_bootstrap(result, calls)

    def test_invalid_key_is_not_installed(self):
        result, calls = self.run_bootstrap({"BAD_KEY": "1"}, with_key=True)
        self.assert_no_bootstrap(result, calls)
        self.assertFalse(any(c["tool"] == "kubectl" and "create" in c["args"] for c in calls))

    def test_original_key_is_installed_before_flux(self):
        result, calls = self.run_bootstrap({"MISSING_KEY": "1"}, with_key=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        bootstrap = next(i for i, c in enumerate(calls) if c["tool"] == "flux" and c["args"][:2] == ["bootstrap", "git"])
        secret = next(i for i, c in enumerate(calls) if c["tool"] == "kubectl" and "--from-file=" in " ".join(c["args"]))
        self.assertLess(secret, bootstrap)
        self.assertTrue(calls[bootstrap]["git_password_set"])
        self.assertTrue(any(a.startswith("--version=v") for a in calls[bootstrap]["args"]))
        self.assertNotIn("test-github-token", result.stdout + result.stderr)
        self.assertNotIn("decrypted-credential", result.stdout + result.stderr)

    def test_failed_application_or_helm_release_never_reports_completion(self):
        for flag in ("FAILED_TIER", "FAILED_HELM", "FAILED_PROXY"):
            with self.subTest(flag=flag):
                result, calls = self.run_bootstrap({flag: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Bootstrap complete", result.stdout)
                self.assertIn("Bootstrap failed", result.stderr)
                self.assertTrue(any(c["tool"] == "flux" and "get" in c["args"] for c in calls))

    def test_existing_key_can_be_reused_and_all_releases_are_checked(self):
        result, calls = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Bootstrap complete", result.stdout)
        self.assertFalse(any(c["tool"] == "kubectl" and "create" in c["args"] for c in calls))
        self.assertTrue(any(c["tool"] == "kubectl" and "helmreleases.helm.toolkit.fluxcd.io" in c["args"] for c in calls))
        self.assertTrue(any(c["tool"] == "kubectl" and "rollout" in c["args"] for c in calls))

    def test_retired_home_is_rejected(self):
        result, calls = self.run_bootstrap(environment="home")
        self.assert_no_bootstrap(result, calls)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
