# EKS Production Stack

Production-grade EKS cluster infrastructure built with Terraform, designed to support a full three-tier application stack managed via Helm and Helmfile.

## Architecture

```
AWS
├── VPC (custom module)
│   ├── 2 Public subnets  — NAT Gateway, ALB entry point
│   └── 2 Private subnets — EKS nodes (tagged for internal-elb)
│
├── EKS Cluster  (terraform-aws-modules/eks)
│   ├── OIDC provider (IRSA enabled)
│   └── system node group — t3.medium, min 1 / max 3
│       └── taint: CriticalAddonsOnly=true:NoSchedule
│
├── Karpenter  (EKS submodule)
│   ├── Controller IAM role (IRSA)
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

Instead of multiple managed node groups, Karpenter handles workload node provisioning dynamically via two NodePools (defined in Helm/Helmfile):

| NodePool | Labels | Instances | Purpose |
|---|---|---|---|
| `app-nodepool` | `role=app` | spot + on-demand, c/m/r | Frontend + Backend |
| `db-nodepool` | `role=db` | on-demand only, r-family | Database (tainted) |

The single managed node group (`system`) runs only Karpenter, CoreDNS, and other critical add-ons.

## Repository Structure

```
.
├── terraform/
│   ├── main.tf            # VPC, EKS, Karpenter modules
│   ├── s3.tf              # Backup bucket + lifecycle policy
│   ├── irsa.tf            # IRSA roles for ExternalDNS, ExternalSecrets, backups
│   ├── variables.tf       # Variable definitions
│   ├── terraform.tfvars   # Variable values — edit this to customize
│   ├── outputs.tf         # ARNs and names needed by Helmfile
│   ├── versions.tf        # (reserved for backend config)
│   └── modules/
│       ├── bootstrap/     # S3 state bucket + DynamoDB lock table
│       └── vpc/           # VPC, subnets, NAT gateway, route tables
```

## Prerequisites

- Terraform >= 1.15
- AWS CLI configured with sufficient permissions
- An AWS account and a Route53 hosted zone (for ExternalDNS)

## Usage

### 1. Bootstrap (first time only)

Create the S3 backend for Terraform state:

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

### 4. Get Helmfile values

After apply, retrieve the ARNs needed for Helmfile:

```bash
terraform output
```

## What Comes Next (Helm / Helmfile layer)

| Section | Component |
|---|---|
| 2 | Helm charts — Frontend, Backend, Database (Bitnami wrapper) |
| 3 | Helmfile orchestration |
| 4 | Node affinity + taints in charts |
| 5 | kube-prometheus-stack (Prometheus + Grafana) |
| 6 | HPA + VPA |
| 7 | Database backup CronJob |
| 8 | ExternalDNS |
| 9 | ExternalSecrets Operator |
| 10 | Karpenter NodePools + EC2NodeClass |
