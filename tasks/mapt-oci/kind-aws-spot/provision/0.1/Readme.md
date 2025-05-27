# 🚀 Tekton Task: `kind-aws-provision`

**Version:** 0.1

Create a Kind (Kubernetes in Docker) cluster on AWS using the [Mapt CLI](https://github.com/redhat-developer/mapt).
This task is ideal for managing **ephemeral clusters** in Tekton-based CI/CD workflows.

---

## ✅ Requirements

- Tekton Pipelines v0.44.x or newer
- Valid AWS credentials stored as a Kubernetes Secret

---

## 📘 Overview

This task provisions a single-node Kubernetes cluster on AWS using Mapt. It outputs a `kubeconfig` as a Kubernetes Secret for use in later pipeline steps.

### Supported Features

- Spot instance provisioning for cost savings
- Nested virtualization support
- Customizable CPU, memory, and architecture
- Optional timeout for auto-destroy
- Owner-referenced Secret creation for lifecycle management

---

## 🔧 Parameters

| Name                          | Description                                                                 | Default     | Required |
|-------------------------------|-----------------------------------------------------------------------------|-------------|----------|
| `secret-aws-credentials`      | Kubernetes Secret with AWS credentials (`access-key`, `secret-key`, etc.)  | —           | ✅       |
| `id`                          | Unique identifier for the Kind cluster environment                         | —           | ✅       |
| `cluster-access-secret-name` | Optional: name for the output kubeconfig Secret                             | `''`        | ❌       |
| `ownerKind`                   | Type of resource owning the Secret (`PipelineRun`, `TaskRun`)               | `PipelineRun`| ❌       |
| `ownerName`                   | Name of the owning resource                                                 | —           | ✅       |
| `ownerUid`                    | UID of the owning resource                                                  | —           | ✅       |
| `arch`                        | Instance architecture (`x86_64`, `arm64`)                                   | `x86_64`    | ❌       |
| `cpus`                        | Number of vCPUs to provision                                                | `16`        | ❌       |
| `memory`                      | Memory in GiB                                                               | `64`        | ❌       |
| `nested-virt`                 | Enable nested virtualization                                                | `false`     | ❌       |
| `spot`                        | Use spot instances                                                          | `true`      | ❌       |
| `spot-increase-rate`         | % increase on spot price to improve instance allocation                     | `20`        | ❌       |
| `version`                     | Kubernetes version                                                          | `v1.32`     | ❌       |
| `tags`                        | AWS resource tags                                                           | `''`        | ❌       |
| `debug`                       | Enable verbose output (prints credentials; use with caution)               | `false`     | ❌       |
| `timeout`                     | Auto-destroy timeout (`1h`, `30m`, etc.)                                    | `''`        | ❌       |

---

## 📤 Result

| Result                   | Description                                                   |
|--------------------------|---------------------------------------------------------------|
| `cluster-access-secret` | Name of the generated Kubernetes Secret containing kubeconfig  |

### Example output Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <generated-or-specified-name>
type: Opaque
data:
  kubeconfig: <base64-encoded>
```

---

## 🔐 AWS Credentials Secret Format

Create a Kubernetes Secret like this:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aws-my-creds
type: Opaque
data:
  access-key: <base64>
  secret-key: <base64>
  region: <base64>
  bucket: <base64>
```

---

## 📦 Example: How to Use the Kubeconfig in Another Task

After provisioning the cluster, you can retrieve and use the generated `kubeconfig` in tasks steps.
**Use a shared `emptyDir` volume to persist and access the kubeconfig.**

```yaml
- name: get-kubeconfig
  image: quay.io/konflux-ci/tekton-integration-catalog/utils:latest
  workingDir: /var/workdir
  volumeMounts:
    - name: kubeconfig-vol
      mountPath: /var/workdir
  script: |
    #!/bin/bash
    set -euo pipefail

    echo "[INFO] Retrieving kubeconfig from secret: $(params.cluster-access-secret) in namespace: $(params.namespace)"
    KUBECONFIG_B64=$(kubectl get secret "$(params.cluster-access-secret)" -n "$(params.namespace)" -o jsonpath='{.data.kubeconfig}' || true)

    if [[ -z "$KUBECONFIG_B64" ]]; then
      echo "[ERROR] Kubeconfig not found in secret $(params.cluster-access-secret) in namespace $(params.namespace)."
      exit 1
    fi

    mkdir -p /var/workdir/.kube
    echo "$KUBECONFIG_B64" | base64 -d > /var/workdir/.kube/config
    chmod 400 /var/workdir/.kube/config

    echo "[INFO] Verifying access to the target cluster..."
    kubectl cluster-info
```

### Volume Declaration Example

Ensure your `Task` includes a shared volume like this:

```yaml
volumes:
  - name: kubeconfig-vol
    emptyDir: {}
```
