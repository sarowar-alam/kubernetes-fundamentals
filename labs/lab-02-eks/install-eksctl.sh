#!/usr/bin/env bash
# =============================================================================
# install-eksctl.sh
# Downloads and installs the latest eksctl binary on Linux/macOS.
#
# eksctl is the official CLI for creating EKS clusters.
# It reads a cluster config YAML and handles everything:
#   - VPC, subnets, security groups
#   - IAM roles
#   - EKS control plane
#   - Node groups (EC2 instances)
#   - Addons (CoreDNS, kube-proxy, etc.)
#
# Usage:
#   chmod +x install-eksctl.sh
#   ./install-eksctl.sh
#
# Tested on: Ubuntu 22.04, macOS 13+
# =============================================================================

set -euo pipefail

echo "=================================================="
echo "  Installing eksctl"
echo "=================================================="

# Detect OS
OS="$(uname -s)"
ARCH="$(uname -m)"

case "${ARCH}" in
  x86_64)  ARCH_NAME="amd64" ;;
  aarch64) ARCH_NAME="arm64" ;;
  arm64)   ARCH_NAME="arm64" ;;
  *)
    echo "[ERROR] Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

case "${OS}" in
  Linux)  OS_NAME="linux"  ;;
  Darwin) OS_NAME="darwin" ;;
  *)
    echo "[ERROR] Unsupported OS: ${OS}"
    echo "  For Windows, use WSL2 or GitHub Releases manually."
    exit 1
    ;;
esac

DOWNLOAD_URL="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${OS_NAME}_${ARCH_NAME}.tar.gz"

echo "[INFO] Downloading eksctl for ${OS_NAME}/${ARCH_NAME}..."
curl -sL "${DOWNLOAD_URL}" | tar xz -C /tmp

echo "[INFO] Moving eksctl to /usr/local/bin..."
sudo mv /tmp/eksctl /usr/local/bin/eksctl
sudo chmod +x /usr/local/bin/eksctl

echo ""
echo "[OK] eksctl installed:"
eksctl version

echo ""
echo "=================================================="
echo "  EKSCTL READY"
echo "=================================================="
echo ""
echo "  Also ensure these are installed and configured:"
echo "    - AWS CLI v2   : aws --version"
echo "    - kubectl      : kubectl version --client"
echo "    - AWS profile  : aws configure --profile sop"
echo ""
echo "  Next step: create EKS cluster:"
echo "    eksctl create cluster -f labs/lab-02-eks/cluster-config.yaml"
echo ""
