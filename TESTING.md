# Verification and Chaos Testing Guide

This document outlines the step-by-step procedures to verify that all components of the EKS Production Stack are functioning correctly. It is based on the integration and chaos testing requirements from the DevOps exercises.

---

## 1. Pods & Scheduling Verification

Verify that all workloads are running and correctly placed on the appropriate nodes (Node Affinity and Taints/Tolerations).

### Check Pod Status
Ensure all pods across all namespaces are in a `Running` state:
```bash
kubectl get pods -A
```

### Check Node Placement
Verify that `frontend` and `backend` pods are running on `app-nodepool` nodes, and `database` is running on a dedicated `db-nodepool` node:
```bash
# Get pod placement details
kubectl get pods -n production -o wide

# Check node labels to verify placement matches the node pools
kubectl get nodes --show-labels
```

---

## 2. Secrets Management (ExternalSecrets)

Verify that AWS Secrets Manager credentials are successfully syncing into Kubernetes Secrets.

### Check Sync Status
```bash
kubectl get externalsecrets -n production
# Output should show status "SecretSynced" for db-credentials
```

### Verify the Secret Exists
Ensure the actual Kubernetes Secret was generated and contains the mapped keys:
```bash
kubectl get secret db-credentials -n production -o yaml
```
*(Verify that the backend is successfully reading this secret to connect to the database, meaning no CrashLoopBackOff errors).*

---

## 3. Autoscaling (HPA & VPA)

Verify that both Horizontal and Vertical Pod Autoscalers are active and functioning.

### Verify HPA
Check that HPA is actively tracking metrics (CPU/Memory) for frontend and backend:
```bash
kubectl get hpa -n production
# TARGETS should show current% / target% (e.g., 5% / 70%)
```

### Verify VPA Recommendations
Since VPA is configured in `updateMode: "Off"` (recommendation only), check the recommended resource requests:
```bash
kubectl describe vpa -n production
```
*(Scroll to the `Status.Recommendation` section to see the target CPU/Memory for your containers).*

---

## 4. Monitoring (Prometheus & Grafana)

Verify that the `kube-prometheus-stack` is scraping your applications.

### Port-forward to Prometheus
```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
```
1. Open `http://localhost:9090` in your browser.
2. Go to **Status** -> **Targets**.
3. Verify that the `frontend`, `backend`, and `database` ServiceMonitors are listed and show a state of `UP`.

### Port-forward to Grafana
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```
1. Open `http://localhost:3000` (Login with `admin` and the password defined in your AWS Secrets).
2. Check the pre-provisioned dashboards (e.g., Node Exporter, Kubernetes Compute Resources, PostgreSQL) and verify real data is flowing.

---

## 5. Database Backups to S3

Test the automated backup CronJob by triggering a manual run.

### Trigger a Manual Backup
```bash
# Get the exact name of your cronjob
kubectl get cronjob -n production

# Create a manual job from the cronjob (replace <cronjob-name> with the actual name)
kubectl create job --from=cronjob/<cronjob-name> manual-backup-test -n production
```

### Verify the Backup
Watch the job complete:
```bash
kubectl get pods -n production -w
kubectl logs -f job/manual-backup-test -n production
```
Once completed, check your AWS S3 bucket using the AWS CLI to ensure the `.sql.gz` file exists:
```bash
aws s3 ls s3://<your-backup-bucket-name>/backups/
```

---

## 6. Networking & DNS (ExternalDNS)

Verify that Ingress resources successfully created DNS records in Route53.

### Check ExternalDNS Logs
```bash
kubectl logs -l app.kubernetes.io/name=external-dns -n external-dns -f
```
*(Look for logs indicating that `UPSERT` operations were sent to AWS Route53).*

### Test Resolution
Use `dig` to verify that your domains resolve to the ALB address:
```bash
dig app.example.com
dig api.example.com
```

---

## 7. Chaos Testing (Resiliency Checks)

Test the self-healing capabilities of the cluster.

### 1. Pod Failure
Kill a frontend pod and watch the ReplicaSet immediately replace it:
```bash
kubectl delete pod -l app.kubernetes.io/name=frontend -n production
kubectl get pods -n production -w
```

### 2. Secret Deletion
Delete the generated Kubernetes Secret and watch the ExternalSecrets Operator instantly recreate it:
```bash
kubectl delete secret db-credentials -n production
sleep 5
kubectl get secret db-credentials -n production
```

### 3. High Load Simulation
Run a load test against the frontend to trigger HPA scale-up and Karpenter node provisioning.
```bash
# Run a temporary pod to generate traffic (using hey or curl)
kubectl run load-generator --rm -ti --image=williamyeh/hey -- \
  hey -z 2m -c 50 http://frontend-service.production.svc.cluster.local
```
While running, open another terminal and watch the cluster scale:
```bash
# Watch HPA increase replicas
kubectl get hpa -n production -w

# Watch Karpenter provision new nodes when pods go into Pending state
kubectl get nodeclaims -w
kubectl get nodes -w
```

### 4. Database Persistence Test
Delete the database pod to test the StatefulSet and PVC:
```bash
kubectl delete pod database-postgresql-0 -n production
```
Wait for the pod to recreate. Once running, connect to the database and verify that your data is still intact (the `gp3` EBS volume was successfully reattached).

### 5. Node Draining
Drain an application node to simulate a spot interruption or node upgrade:
```bash
# Find an app node
kubectl get nodes -l role=app

# Drain it safely
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```
Watch the workloads automatically reschedule to other nodes. Karpenter will recognize the sudden resource demand and provision a replacement node seamlessly.
