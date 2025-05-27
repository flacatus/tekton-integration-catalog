# 🚀 Tekton Task: `kind-aws-deprovision`

**Version:** 0.1

Safely deprovision a Kind cluster on AWS that was previously created using the `kind-aws-provision` task.
This task is designed to clean up temporary infrastructure and optionally collect and store diagnostics before destruction.

---

## 📘 Overview

This task uses the [Mapt CLI](https://github.com/redhat-developer/mapt) to tear down infrastructure created for ephemeral Kubernetes clusters.
In addition to the basic teardown, it can optionally:

- Retrieve and use the cluster’s `kubeconfig`
- Collect artifacts from the cluster (logs, metrics)
- Push collected artifacts to an OCI-compliant registry

### Key Features

- Safe and scoped cluster destruction based on a unique ID
- Uses AWS credentials from a Kubernetes Secret
- Supports debug mode for troubleshooting
- Artifact collection and optional registry upload

---

## 🔧 Parameters

| Name                        | Description                                                                                     | Default | Required |
|-----------------------------|-------------------------------------------------------------------------------------------------|---------|----------|
| `secret-aws-credentials`    | Kubernetes Secret name containing AWS credentials (`access-key`, `secret-key`, etc.)            | —       | ✅       |
| `id`                        | Unique identifier for the Kind cluster environment to destroy                                   | —       | ✅       |
| `debug`                     | Enable verbose output (prints sensitive info, use with caution)                                 | `false` | ❌       |
| `pipeline-aggregate-status`| Status of the overall pipeline run (e.g., Succeeded, Failed). Used for conditional logic.       | `None`  | ❌       |
| `cluster-access-secret`     | Name of the Kubernetes Secret containing the base64-encoded kubeconfig                          | —       | ✅       |
| `namespace`                | Kubernetes namespace where the kubeconfig Secret is located                                     | —       | ✅       |
| `oci-container`            | ORAS-compliant OCI registry reference where collected artifacts will be pushed                  | —       | ✅       |

---

## 🪄 Steps Breakdown

### ✅ Step: `get-kubeconfig`

Fetches the `kubeconfig` from a Kubernetes Secret and writes it to `/var/workdir/.kube/config`.

### ✅ Step: `collect-artifacts`

If the pipeline did not succeed, this step gathers logs and system artifacts from the cluster.

### ✅ Step: `secure-push-oci`

Pushes the collected artifacts to the provided OCI registry for archiving or debugging.

### ✅ Step: `destroy`

Uses the Mapt CLI to destroy the Kind cluster based on the provided environment ID.

---

## ✅ Requirements

- Tekton Pipelines v0.44.x or newer
- Kubernetes Secret with valid AWS credentials

---

## ⚠️ Notes

- **Graceful Failures**: Most steps have `onError: continue`, which ensures that even in failed pipelines, diagnostics can be gathered before final cleanup.
