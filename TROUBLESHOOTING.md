# Troubleshooting and Fixes Report - EKS Production Stack

This document centralizes all issues and errors encountered in the project (both at the Terraform code level and the Helm/Kubernetes configuration level), explains why they occurred, and details how they were resolved to produce a stable, production-ready, end-to-end environment.

---

## 1. CrashLoopBackOff & Missing CRDs in Vertical Pod Autoscaler (VPA)
* **Problem Description:** VPA pods (`vpa-recommender`, `vpa-updater`, and `vpa-admission-controller`) crashed repeatedly and failed to start.
* **Root Cause:**
  1. The Helmfile attempted to install the VPA chart without the required Custom Resource Definitions (CRDs) (such as `VerticalPodAutoscaler`), preventing the services from running.
  2. The `helm/values/vpa.yaml` file contained duplicate/conflicting parameter flags under the `args` fields of the pods, which caused container startup failures.
* **The Fix:**
  * Added `installCRDs: true` to the VPA release configuration in `helmfile.yaml`.
  * Cleaned up duplicate and conflicting arguments in `vpa.yaml`.

**Example Diff:**
```yaml
# helmfile.yaml
  - name: vpa
    namespace: kube-system
    chart: cowboysysop/vertical-pod-autoscaler
+   installCRDs: true
    values:
    - ./values/vpa.yaml
```

```yaml
# helm/values/vpa.yaml (Example Fix)
  recommender:
    extraArgs:
      v: "4"
-     prometheus-address: http://prometheus-operated.monitoring.svc
-     storage: prometheus
```

---

## 2. Karpenter API Version Mismatch
* **Problem Description:** Karpenter resource manifests for configuring node provisioning failed during `kubectl apply`.
* **Root Cause:** The manifests used an outdated/incorrect API version (`karpenter.sh/v1beta1`) that did not match the Karpenter version running in the cluster.
* **The Fix:** Updated `nodepool.yaml` to use `karpenter.sh/v1` and `ec2nodeclass.yaml` to use `karpenter.k8s.aws/v1` in accordance with the latest Karpenter documentation.

**Example Diff:**
```diff
# helm/manifests/nodepool.yaml
- apiVersion: karpenter.sh/v1beta1
+ apiVersion: karpenter.sh/v1
   kind: NodePool
   metadata:
     name: app-nodepool
```

```diff
# helm/manifests/ec2nodeclass.yaml
- apiVersion: karpenter.k8s.aws/v1beta1
+ apiVersion: karpenter.k8s.aws/v1
   kind: EC2NodeClass
```

---

## 3. Karpenter "No Subnets Found" Error
* **Problem Description:** Even though Karpenter was running, it failed to provision EC2 instances, logging errors that it could not find subnet resources.
* **Root Cause:** In Terraform, the VPC module (`modules/vpc/main.tf`) tagged private subnets with `karpenter.sh/discovery = eks-production-stack-cluster` (derived from `${var.project_name}-cluster`). However, the actual cluster was named `eks-production-cluster`. Karpenter could not discover the subnets because of this tag mismatch.
* **The Fix:** Updated the tags in `main.tf` to match the exact cluster name (`eks-production-cluster`) and ran `terraform apply`.

**Example Diff:**
```diff
# terraform/modules/vpc/main.tf
   private_subnet_tags = {
     "kubernetes.io/role/internal-elb" = "1"
-    "karpenter.sh/discovery"          = "${var.project_name}-cluster"
+    "karpenter.sh/discovery"          = "eks-production-cluster"
   }
```

---

## 4. Karpenter AWS AccessDenied Error
* **Problem Description:** Once Karpenter discovered the subnets, it encountered an `AccessDenied` error when trying to provision EC2 instances.
* **Root Cause:** The static `ec2nodeclass.yaml` referenced an outdated IAM Role ARN from a previous run. Every time Terraform is destroyed and recreated, it generates new role names/ARNs, leaving the hardcoded reference invalid.
* **The Fix:** Added a dynamic replacement step (`sed`) in `scripts/generate-values.sh` to extract the fresh Karpenter Node Role ARN from the Terraform output and inject it into `ec2nodeclass.yaml` automatically prior to application.

**Example Fix:**
```bash
# Error logged by Karpenter:
# AccessDenied: User is not authorized to perform: iam:PassRole on resource

# Fix: Dynamically inject the role into ec2nodeclass.yaml in scripts/generate-values.sh
sed -i "s/role: Karpenter-.*/role: ${KARPENTER_NODE_ROLE}/" "$EC2NODECLASS_FILE"
```

---

## 5. External Secrets Pods Stuck in Pending
* **Problem Description:** The pods responsible for fetching secrets from AWS Secrets Manager remained stuck in `Pending`.
* **Root Cause:** The only active nodes in the cluster (Fargate or Managed Node Groups) carried the `CriticalAddonsOnly` taint, blocking regular workloads. Because of issues #3 and #4, Karpenter was unable to spin up app nodes to host these pods.
* **The Fix:** Once the subnet tags and IAM role permissions for Karpenter were fixed, Karpenter immediately provisioned a node for `app-nodepool`, allowing the External Secrets pods to schedule and run.

```bash
# Output from 'kubectl describe pod' when failing:
# Warning  FailedScheduling  default-scheduler  0/2 nodes are available: 2 node(s) had untolerated taint {CriticalAddonsOnly: true}.
```

---

## 6. External Secrets InvalidProviderConfig Error
* **Problem Description:** The backend pod crashed with `CreateContainerConfigError` because it could not find the `db-credentials` secret. The `ClusterSecretStore` was in an error state.
* **Root Cause:** The Helm values for External Secrets (`helm/values/external-secrets.yaml`) left the IRSA role annotation empty: `eks.amazonaws.com/role-arn: ""`, preventing the controller from authenticating with AWS Secrets Manager.
* **The Fix:** Added an automation step to `scripts/generate-values.sh` using `sed` to inject the dynamically generated IAM Role ARN from Terraform into the values file.

**Example Diff:**
```diff
# Error logged by ClusterSecretStore:
# Warning  InvalidProviderConfig  cluster-secret-store  unable to create session: an IAM role must be associated

# Fix: Added to scripts/generate-values.sh
+ sed -i "s|eks.amazonaws.com/role-arn: .*|eks.amazonaws.com/role-arn: "${EXTERNAL_SECRETS_ROLE_ARN}"|" "$EXT_SECRETS_FILE"
```

---

## 7. Database Pod Stuck in Pending due to Missing StorageClass
* **Problem Description:** The PostgreSQL pod `database-postgresql-0` remained stuck in `Pending`. The events indicated that the `PersistentVolumeClaim` (PVC) could not be bound because the requested StorageClass `gp3` did not exist.
* **Root Cause:** The PostgreSQL Helm chart requested the `gp3` storage class, which is not configured by default in AWS EKS.
* **The Fix:** 
  1. Created `helm/manifests/gp3-storageclass.yaml` defining the `gp3` storage class (backed by the EBS CSI driver).
  2. Added a `kubectl apply` step in `scripts/deploy.sh` to register the StorageClass before deploying the database.

**Manifest Code:**
```yaml
# helm/manifests/gp3-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  fsType: ext4
```

---

## 8. Prometheus (kube-prometheus-stack) Installation Errors
* **Problem Description:** `helmfile sync` failed when installing the Prometheus and Grafana stack.
* **Root Cause:** The custom values file `monitoring.yaml` contained YAML syntax errors, missing/mismatched labels in `serviceMonitors` blocks, and invalid api-version configurations.
* **The Fix:** Corrected YAML syntax and aligned labels in `monitoring.yaml` to allow Helm to deploy the resources successfully.

**Example Diff:**
```diff
# helm/values/monitoring.yaml
  additionalServiceMonitors:
    - name: frontend-monitor
+     selector:
+       matchLabels:
+         app.kubernetes.io/name: frontend
      endpoints:
        - port: http
```

---

## 9. Webhook Timeout / Hang on Teardown (destroy.sh)
* **Problem Description:** Running the teardown script `destroy.sh` caused the process to hang on deleting `external-secret.yaml` due to a Webhook timeout.
* **Root Cause:** The teardown script deleted Karpenter resources first, immediately terminating the nodes hosting the External Secrets webhook pod. When Kubernetes tried to validate the deletion of the `ExternalSecret` resource, the webhook was unreachable, creating a deadlock.
* **The Fix:** Rearranged the resource deletion order in `destroy.sh` so that Kubernetes resources and Secrets are deleted *before* terminating the Karpenter nodes and node pools.

**Example Diff:**
```diff
# scripts/destroy.sh
- kubectl delete -f "$HELM_DIR/manifests/nodepool.yaml"
- kubectl delete -f "$HELM_DIR/manifests/ec2nodeclass.yaml"
- kubectl delete -f "$HELM_DIR/manifests/external-secret.yaml"
- kubectl delete -f "$HELM_DIR/manifests/cluster-secret-store.yaml"

# Fix: Delete secrets BEFORE Karpenter nodes are terminated
+ kubectl delete -f "$HELM_DIR/manifests/external-secret.yaml"
+ kubectl delete -f "$HELM_DIR/manifests/cluster-secret-store.yaml"
+ kubectl delete -f "$HELM_DIR/manifests/nodepool.yaml"
+ kubectl delete -f "$HELM_DIR/manifests/ec2nodeclass.yaml"
```

---

## 10. ImagePullBackOff in Database Backup CronJob
* **Problem Description:** The database backup CronJob failed with `ImagePullBackOff`. Additionally, it was stuck in `Pending` when it couldn't schedule on database nodes.
* **Root Cause:**
  1. The image tag was incorrectly configured as `18.7.0` (which is the Helm Chart version, not the actual Docker image tag). The Bitnami image tag requires a suffix (e.g., `18.4.0-debian-12`).
  2. The CronJob lacked the proper tolerations and node affinity to run on database-specific nodes (which carry taints to prevent other pods from scheduling on them).
  3. Pulling from Docker Hub occasionally hit rate limits due to the AWS NAT Gateway.
* **The Fix:**
  * Updated the registry to pull from AWS ECR Public: `public.ecr.aws/bitnami/postgresql`.
  * Referenced the correct PostgreSQL image tag from values: `{{ .Values.postgresql.image.tag }}`.
  * Added tolerations and node affinity to the CronJob template.

**Example Diff:**
```diff
# helm/charts/database/templates/postgres-backup-cronjob.yaml
          containers:
            - name: backup
-             image: bitnami/postgresql:18.7.0
+             image: public.ecr.aws/bitnami/postgresql:{{ .Values.postgresql.image.tag | default "18.4.0" }}

        spec:
          serviceAccountName: backup-sa
+         tolerations:
+           - key: "workload"
+             operator: "Equal"
+             value: "database"
+             effect: "NoSchedule"
+         affinity:
+           nodeAffinity:
+             requiredDuringSchedulingIgnoredDuringExecution:
+               nodeSelectorTerms:
+                 - matchExpressions:
+                     - key: "role"
+                       operator: "In"
+                       values:
+                         - "db"
```

---

## 11. Advanced Database Backup Troubleshooting
*This section covers resolving sequential errors discovered during execution.*

**1. Registry Pull Failures (`ErrImagePull - bitnami/postgresql:18.4.0`)**
* **Root Cause:** Bitnami stopped publishing specific tag versions to Docker Hub.
* **The Fix:** Switched the registry to AWS ECR Public: `public.ecr.aws/bitnami/postgresql:18.4.0`.

**2. Invalid `awscli` Executable Path (`No such file or directory`)**
* **Root Cause:** The `cp -r` command in the initContainer copied the `current` symlink as a plain text file, breaking the executable lookup.
* **The Fix:** Re-created the symlink dynamically during the initContainer execution:
```bash
ln -sfn /tools/aws-cli/v2/$(ls /tools/aws-cli/v2/ | grep -v current) /tools/aws-cli/v2/current
```

**3. Entrypoint Conflict with `amazon/aws-cli` Image**
* **Root Cause:** The AWS CLI Docker image executes the `aws` binary by default as its entrypoint, causing our shell commands (`cp`) to be interpreted as arguments to AWS CLI (e.g., `aws cp`).
* **The Fix:** Overwrote the container entrypoint by setting `command: ["/bin/sh", "-c"]`.

**4. Database Password Authentication Failed**
* **Root Cause:** The database persistent volume (PVC) retained the old password (`secret_password`), while the newly generated Secrets and CronJob used a dynamically generated password (`123456`).
* **The Fix:** Deleted the old database PVC and restarted the pod, forcing PostgreSQL to re-initialize using the new password secret.

**5. Chart `existingSecret` Misconfiguration**
* **Root Cause:** The Bitnami PostgreSQL chart did not know which keys to read from our custom `db-credentials` secret.
* **The Fix:** Added explicit key mappings under the `auth` section in the values configuration:
```yaml
postgresql:
  auth:
    existingSecret: "db-credentials"
    secretKeys:
      adminPasswordKey: password
      userPasswordKey: password
```

**6. Directory Permission Denied (`Permission denied: /.aws`)**
* **Root Cause:** The AWS CLI attempted to write configuration files to `/`, which failed because the Bitnami container runs under a non-root user (UID 1001) for security.
* **The Fix:** Set the `HOME` environment variable to a writable temporary directory:
```yaml
- name: HOME
  value: /tmp
```

---

## 12. AWS Load Balancer Controller (ALB) Troubleshooting

**1. AWS Load Balancer Controller - MissingEndpoint**
* **Root Cause:** The controller failed with `MissingEndpoint: 'Endpoint' configuration is required for this service`. This was because the region and VPC configurations failed to parse correctly when defined inline in `helmfile.yaml`'s `set:` block due to formatting/quote parsing issues.
* **The Fix:** Moved these configuration values to a dedicated values file generated dynamically by `generate-values.sh` (`values/alb.yaml`) and loaded it via `values:` in `helmfile.yaml`.

**2. AWS Load Balancer Controller - NoCredentialProviders**
* **Root Cause:** The controller pods started without the AWS credentials environment variables. The ServiceAccount annotation `eks.amazonaws.com/role-arn` was missing due to configuration merging issues. Furthermore, since pod identity credentials are injected at pod creation time, existing pods did not receive them even after updating the ServiceAccount.
* **The Fix:** Added the explicit ServiceAccount configuration with annotations to `alb.yaml` and manually restarted the controller pods:
```bash
kubectl delete pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```
This triggered EKS Pod Identity to inject the required `AWS_ROLE_ARN` environment variables upon pod recreation.

---

## 13. External-DNS Troubleshooting

**External-DNS - no EC2 IMDS role found**
* **Root Cause:** The External-DNS logs showed authorization failures when trying to sync Route 53 records. The IAM role annotation in `external-dns.yaml` was empty due to configuration mismatches during Helmfile parsing.
* **The Fix:**
  1. Updated `scripts/generate-values.sh` to inject the correct IAM role ARN into `values/external-dns.yaml` using `sed`.
  2. Applied the configuration changes using `helmfile sync` and restarted the deployment: `kubectl rollout restart deployment external-dns`.

---

## 14. Horizontal Pod Autoscaler (HPA) Troubleshooting

**1. HPA shows Target CPU/Memory as `<unknown>/70%` and fails to scale**
* **Root Cause:** EKS clusters do not include a metrics harvester by default. Without `metrics-server` installed, Kubernetes is unable to fetch CPU and memory usage statistics.
* **The Fix:** Added the official `metrics-server` chart to `helmfile.yaml` and installed it in the `kube-system` namespace.

**2. HPA unable to find target deployment (`FailedGetScale`)**
* **Root Cause:** The `scaleTargetRef` in `hpa.yaml` and `vpa.yaml` referenced the base name (e.g. `backend`), but the actual Deployment resource was defined as `backend-deployment`.
* **The Fix:** Updated the Helm chart templates to point to the correct Deployment resource name:
```diff
# helm/charts/backend/templates/hpa.yaml
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
-   name: {{ include "backend.fullname" . }}
+   name: {{ include "backend.fullname" . }}-deployment
```
