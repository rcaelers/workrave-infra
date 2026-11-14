#!/usr/bin/env python3
"""Admission smoke tests; creates a temporary, label-scoped policy, never pods.

Usage: python3 scripts/check-kyverno-image-policy.py <kube-context>
Requires the migrated verify-guardrail-images ImageValidatingPolicy.
"""
import copy
import json
import subprocess
import sys
import time
import uuid


def main(context):
    prefix = ["kubectl", "--context", context, "--request-timeout=45s"]

    def kubectl(*args, data=None, check=True):
        return subprocess.run(prefix + list(args), input=json.dumps(data) if data else None,
                              text=True, capture_output=True, check=check)

    def get(*args):
        return json.loads(kubectl("get", *args, "-o", "json").stdout)

    policy = get("imagevalidatingpolicy", "verify-guardrail-images")
    image = get("deployment", "guardrail-api", "-n", "guardrail")["spec"]["template"]["spec"]["containers"][0]["image"]
    # Exercise tag-to-digest mutation rather than only an already-pinned image.
    image = image.split("@")[0]
    suffix = uuid.uuid4().hex[:10]
    test_name = "guardrail-image-check-" + suffix
    label = "security.workrave.org/image-policy-check"

    def pod(containers, init=None, namespace="guardrail", labelled=False):
        result = {"apiVersion": "v1", "kind": "Pod", "metadata": {
            "name": test_name, "namespace": namespace}, "spec": {
                "restartPolicy": "Never", "containers": [
                    {"name": "container-" + str(i), "image": item} for i, item in enumerate(containers)]}}
        if init:
            result["spec"]["initContainers"] = [{"name": "init", "image": init}]
        if labelled:
            result["metadata"]["labels"] = {label: suffix}
        return result

    def admit(resource, expected=True, denied_by=None):
        result = kubectl("create", "--dry-run=server", "-f", "-", "-o", "json",
                         data=resource, check=False)
        if expected:
            if result.returncode:
                raise RuntimeError(result.stderr)
            return json.loads(result.stdout)
        if not result.returncode or denied_by not in result.stderr:
            raise RuntimeError("Expected rejection by " + denied_by + ": " + result.stderr)

    admitted = admit(pod([image, "busybox:1.37.0"], init=image))
    for container in [admitted["spec"]["containers"][0], admitted["spec"]["initContainers"][0]]:
        assert "@sha256:" in container["image"], "Guardrail image was not pinned"
    # An unrelated image in Guardrail and a Guardrail-pattern image outside the
    # namespace must not be pulled or verified by this policy.
    admit(pod(["busybox:1.37.0"]))
    admit(pod(["ghcr.io/rcaelers/guardrail-not-a-real-image:policy-check"], namespace="default"))
    print("PASS: signed regular/init images pinned; unrelated images and namespaces unaffected", flush=True)
    missing = "ghcr.io/rcaelers/guardrail-not-a-real-image:policy-check"
    admit(pod([missing]), False, "verify-guardrail-images")
    admit(pod(["busybox:1.37.0"], init=missing), False, "verify-guardrail-images")
    deployment = {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {
        "name": test_name, "namespace": "guardrail"}, "spec": {
            "selector": {"matchLabels": {"app": test_name}}, "template": {
                "metadata": {"labels": {"app": test_name}}, "spec": pod([image])["spec"]}}}
    deployment["spec"]["template"]["spec"]["restartPolicy"] = "Always"
    admitted = admit(deployment)
    assert "@sha256:" in admitted["spec"]["template"]["spec"]["containers"][0]["image"]
    deployment["spec"]["template"]["spec"]["containers"][0]["image"] = missing
    admit(deployment, False, "verify-guardrail-images")
    running = get("pods", "-n", "guardrail", "-l", "app=guardrail-api")["items"][0]
    existing = running["spec"].get("ephemeralContainers", [])
    for reference, expected in [(image, True), (missing, False)]:
        patch = {"spec": {"ephemeralContainers": existing + [{"name": test_name,
            "image": reference, "command": ["true"]}]}}
        result = kubectl("patch", "pod", running["metadata"]["name"], "-n", "guardrail",
                         "--subresource=ephemeralcontainers", "--type=merge", "--dry-run=server",
                         "-p", json.dumps(patch), "-o", "json", check=False)
        if expected and result.returncode:
            raise RuntimeError(result.stderr)
        if not expected and (not result.returncode or "verify-guardrail-images" not in result.stderr):
            raise RuntimeError("Expected ephemeral-image rejection: " + result.stderr)
    print("PASS: pod, init, deployment and ephemeral-container admission enforced", flush=True)

    probe = {"apiVersion": policy["apiVersion"], "kind": policy["kind"],
             "metadata": {"name": test_name}, "spec": copy.deepcopy(policy["spec"])}
    # Only dry-run pods carrying this unpredictable test label can match.
    probe["spec"]["autogen"] = {"podControllers": {"controllers": []}}
    probe["spec"]["matchConstraints"]["objectSelector"] = {"matchLabels": {label: suffix}}
    probe["spec"]["matchImageReferences"] = [{"glob": "*"}]

    def install_probe():
        kubectl("apply", "--server-side", "--field-manager=workrave-policy-check", "-f", "-", data=probe)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            current = get("imagevalidatingpolicy", test_name)
            if current.get("status", {}).get("conditionStatus", {}).get("ready"):
                return
            time.sleep(1)
        raise RuntimeError("Temporary test policy did not become ready")

    probes = [test_name]
    try:
        install_probe()
        # Positive control proves that the test policy's trust settings work.
        admit(pod([image], labelled=True))
        admit(pod(["busybox:1.37.0"], labelled=True), False, test_name)
        admit(pod([image], init="busybox:1.37.0", labelled=True), False, test_name)
        print("PASS: unsigned regular and init images rejected by the migrated verification logic", flush=True)
        # A valid signature from a different workflow must also be rejected.
        kubectl("delete", "imagevalidatingpolicy", test_name)
        test_name += "-signer"
        probes.append(test_name)
        probe["metadata"]["name"] = test_name
        probe["spec"]["attestors"][0]["cosign"]["keyless"]["identities"][0]["subjectRegExp"] = "^https://github[.]com/rcaelers/not-guardrail/.*$"
        install_probe()
        admit(pod([image], labelled=True), False, test_name)
        print("PASS: signed image rejected when its signer does not match the trusted workflow", flush=True)
    finally:
        kubectl("delete", "imagevalidatingpolicy", *probes, "--ignore-not-found")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
