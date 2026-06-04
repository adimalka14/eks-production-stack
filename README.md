# EKS Production Stack

Production-grade EKS cluster with a three-tier application (frontend + backend + database), fully managed via Helm charts and Helmfile.

## Architecture

```
AWS
├── VPC (custom module)
│   ├── 2 Public subnets  — NAT Gateway, ALB entry point
│   └── 2 Private subnets — EKS nodes (tagged for internal-elb)
│
├── EKS Cluster  (terraform-aws-modules/eks v21, AWS provider ~> 6.46)
│   ├── OIDC provider (IRSA enabled)
│   └── system node group — t3.medium, min 1 / max 3
│       └── taint: CriticalAddonsOnly=true:NoSchedule
│
├── Karpenter  (EKS submodule v21, Pod Identity)
│   ├── Controller IAM role
│   ├── Node IAM role + instance profile
│   └── SQS queue + EventBridge rules (spot interruption)
│
├── IRSA Roles  (terraform-aws-modules/iam)
│   ├── external-dns      — Route53 ChangeResourceRecordSets
│   ├── external-secrets  — Secrets Manager GetSecretValue
│   └── backup            — S3 PutObject/GetObject on backup bucket
│
└── S3 backup bucket
    ├── Versioning + SSE-AES256
    └── Lifecycle: Standard-IA (30d) → Glacier (60d) → Delete (90d)
```

## Node Strategy

Karpenter handles workload node provisioning dynamically via two NodePools (defined in Helm/Helmfile):

| NodePool | Labels | Instances | Purpose |
|---|---|---|---|
| `app-nodepool` | `role=app` | spot + on-demand, c/m/r | Frontend + Backend |
| `db-nodepool` | `role=db` | on-demand only, r-family | Database (tainted) |

The single managed node group (`system`) runs only Karpenter, CoreDNS, and other critical add-ons.

## Helm Stack

### Charts

| Chart | Type | Key features |
|---|---|---|
| `charts/frontend` | Custom | Deployment, Service, Ingress (ALB), HPA, VPA, ServiceMonitor |
| `charts/backend` | Custom | Same as frontend + ConfigMap for DB env vars, secretKeyRef for credentials |
| `charts/database` | Bitnami wrapper | PostgreSQL 18.4.0, gp3 persistence, metrics exporter, node affinity, backup CronJob |

### Node Placement

- **Frontend + Backend**: `preferredDuringSchedulingIgnoredDuringExecution` → `role=app` nodes
- **Database**: `requiredDuringSchedulingIgnoredDuringExecution` → `role=db` nodes + toleration for `workload=database:NoSchedule`

### Autoscaling

- **HPA** (frontend + backend): CPU > 70%, memory > 80%, min 2 / max 10 pods
  - Scale-up: doubles pod count every 60s, no stabilization delay
  - Scale-down: 5-minute stabilization window, removes up to 10% every 60s
- **VPA** (all services): `updateMode: Off` — recommendations only, no automatic restarts

### Monitoring (kube-prometheus-stack)

- Prometheus: 7d retention, gp3 persistent storage
- ServiceMonitors on frontend, backend, database
- `serviceMonitorSelectorNilUsesHelmValues: false` — discovers all namespaces
- PrometheusRule: `HighErrorRate` alert (>5% for 5 minutes) on backend
- Grafana dashboards auto-provisioned: node-exporter (1860), k8s-pods (6417), PostgreSQL (9628), Node.js (11159)

### Database Backup (Section 7)

CronJob pattern: **initContainer + emptyDir volume**

```
initContainer (amazon/aws-cli)
  └── copies AWS CLI binary → /tools/ (emptyDir)

main container (bitnami/postgresql:18.4.0)
  └── pg_dump | gzip | aws s3 cp → S3
```

- Schedule: every 6 hours (`0 */6 * * *`)
- Credentials: from `db-credentials` Secret (ExternalSecrets)
- S3 access: via IRSA ServiceAccount (no hardcoded keys)
- `concurrencyPolicy: Forbid` — no overlapping backup jobs

### Helmfile Release Order

```
kube-prometheus-stack  ┐
external-secrets       ├── independent (deploy in parallel)
external-dns           │
karpenter              ┘
database  →  needs: external-secrets
backend   →  needs: database
frontend  →  needs: backend
```

## Repository Structure

```
.
├── terraform/
│   ├── main.tf            # VPC, EKS, Karpenter modules
│   ├── s3.tf              # Backup bucket + lifecycle policy
│   ├── irsa.tf            # IRSA roles for ExternalDNS, ExternalSecrets, backups
│   ├── variables.tf       # Variable definitions
│   ├── terraform.tfvars   # Variable values — edit this to customize
│   ├── outputs.tf         # ARNs needed by Helmfile
│   └── modules/
│       ├── bootstrap/     # S3 state bucket + DynamoDB lock table
│       └── vpc/           # VPC, subnets, NAT gateway, route tables
│
└── helm/
    ├── helmfile.yaml      # All releases with dependency order
    ├── charts/
    │   ├── frontend/
    │   ├── backend/
    │   └── database/      # Bitnami PostgreSQL wrapper
    └── values/            # Per-release override files
```

## Prerequisites

- Terraform >= 1.15
- Helm >= 3.x + helm-diff plugin
- Helmfile >= 1.5
- AWS CLI configured with sufficient permissions
- Route53 hosted zone (for ExternalDNS)

## Usage

### 1. Bootstrap (first time only)

```bash
cd terraform/modules/bootstrap
terraform init && terraform apply
```

Then configure the backend block in `terraform/versions.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "<your-project-name>-tfstate"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "<your-project-name>-tfstate-lock"
  }
}
```

### 2. Deploy infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

### 3. Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-production-cluster
```

### 4. Pass Terraform outputs to Helmfile

```bash
cd terraform
terraform output  # copy ARNs into helm/values/*.yaml
```

### 5. Deploy everything

```bash
cd helm
helm dependency build charts/database
helmfile sync
```

## Remaining Sections

| Section | Component | Status |
|---|---|---|
| 8 | ExternalDNS — Route53 automation | pending |
| 9 | ExternalSecrets — AWS Secrets Manager sync | pending |
| 10 | Karpenter NodePools + EC2NodeClass | pending |
| 11 | Final integration + chaos testing | pending |
