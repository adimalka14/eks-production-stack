#!/bin/bash
set -euo pipefail

# ── Versions ─────────────────────────────────────────────────────────────────
TERRAFORM_VERSION="1.10.5"
KUBECTL_VERSION="1.32.0"
HELM_VERSION="3.17.0"
HELMFILE_VERSION="0.169.2"

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

ok()   { echo "  [ok] $1"; }
skip() { echo "  [skip] $1 already installed"; }
step() { echo ""; echo "━━━ $1 ━━━"; }

need_sudo() {
  if [[ "$EUID" -ne 0 ]]; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}
need_sudo

# ── AWS CLI ───────────────────────────────────────────────────────────────────
step "AWS CLI"
if command -v aws &>/dev/null; then
  skip "aws ($(aws --version 2>&1 | cut -d' ' -f1))"
else
  if [[ "$OS" == "linux" ]]; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp/awscli
    $SUDO /tmp/awscli/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/awscli
  elif [[ "$OS" == "darwin" ]]; then
    curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
    $SUDO installer -pkg /tmp/AWSCLIV2.pkg -target /
    rm /tmp/AWSCLIV2.pkg
  fi
  ok "aws cli installed"
fi

# ── Terraform ─────────────────────────────────────────────────────────────────
step "Terraform ${TERRAFORM_VERSION}"
if command -v terraform &>/dev/null; then
  skip "terraform ($(terraform version -json 2>/dev/null | grep -o '"[0-9.]*"' | head -1 | tr -d '"'))"
else
  curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip" \
    -o /tmp/terraform.zip
  unzip -q /tmp/terraform.zip -d /tmp/terraform-bin
  $SUDO mv /tmp/terraform-bin/terraform /usr/local/bin/terraform
  rm -rf /tmp/terraform.zip /tmp/terraform-bin
  ok "terraform ${TERRAFORM_VERSION}"
fi

# ── kubectl ───────────────────────────────────────────────────────────────────
step "kubectl ${KUBECTL_VERSION}"
if command -v kubectl &>/dev/null; then
  skip "kubectl ($(kubectl version --client -o json 2>/dev/null | grep -o '"v[0-9.]*"' | head -1 | tr -d '"'))"
else
  curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl" \
    -o /tmp/kubectl
  chmod +x /tmp/kubectl
  $SUDO mv /tmp/kubectl /usr/local/bin/kubectl
  ok "kubectl ${KUBECTL_VERSION}"
fi

# ── Helm ──────────────────────────────────────────────────────────────────────
step "Helm ${HELM_VERSION}"
if command -v helm &>/dev/null; then
  skip "helm ($(helm version --short 2>/dev/null | cut -d'+' -f1))"
else
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-${OS}-${ARCH}.tar.gz" \
    | tar -xz -C /tmp
  $SUDO mv /tmp/${OS}-${ARCH}/helm /usr/local/bin/helm
  rm -rf /tmp/${OS}-${ARCH}
  ok "helm ${HELM_VERSION}"
fi

# ── Helmfile ──────────────────────────────────────────────────────────────────
step "Helmfile ${HELMFILE_VERSION}"
if command -v helmfile &>/dev/null; then
  skip "helmfile ($(helmfile version --short 2>/dev/null || helmfile --version 2>/dev/null | head -1))"
else
  curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_${OS}_${ARCH}.tar.gz" \
    | tar -xz -C /tmp helmfile
  $SUDO mv /tmp/helmfile /usr/local/bin/helmfile
  ok "helmfile ${HELMFILE_VERSION}"
fi

# ── helm-diff plugin (required by helmfile) ───────────────────────────────────
step "helm-diff plugin"
if helm plugin list 2>/dev/null | grep -q "^diff"; then
  skip "helm-diff"
else
  helm plugin install https://github.com/databus23/helm-diff
  ok "helm-diff"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━ All dependencies installed ━━━"
echo ""
echo "Versions:"
command -v aws       &>/dev/null && echo "  aws:       $(aws --version 2>&1 | cut -d' ' -f1)"
command -v terraform &>/dev/null && echo "  terraform: $(terraform version | head -1)"
command -v kubectl   &>/dev/null && echo "  kubectl:   $(kubectl version --client --short 2>/dev/null | head -1)"
command -v helm      &>/dev/null && echo "  helm:      $(helm version --short | cut -d'+' -f1)"
command -v helmfile  &>/dev/null && echo "  helmfile:  $(helmfile --version 2>/dev/null | head -1)"
echo ""
echo "Next: configure AWS credentials with 'aws configure' then run scripts/deploy.sh"