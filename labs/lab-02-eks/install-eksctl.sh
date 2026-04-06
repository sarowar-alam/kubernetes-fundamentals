#!/usr/bin/env bash
# =============================================================================
# install-eksctl.sh
# Downloads and installs eksctl AND kubectl on Linux/macOS/Windows.
#
# eksctl is the official CLI for creating EKS clusters.
# kubectl is the Kubernetes CLI for managing cluster workloads.
#
# eksctl reads a cluster config YAML and handles everything:
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
# Tested on: Ubuntu 22.04 | macOS 13+ | Windows 11 Git Bash
# Windows requirement: Chocolatey must be installed (https://chocolatey.org)
# =============================================================================

set -euo pipefail

echo "=================================================="
echo "  Installing eksctl + kubectl"
echo "=================================================="

# ---------------------------------------------------------------------------
# Early-exit guard: skip install if both tools are already present
# ---------------------------------------------------------------------------
EKSCTL_OK=false
KUBECTL_OK=false
if command -v eksctl &>/dev/null; then
  echo "[OK] eksctl is already installed: $(eksctl version)"
  EKSCTL_OK=true
fi
if command -v kubectl &>/dev/null; then
  echo "[OK] kubectl is already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
  KUBECTL_OK=true
fi
if [[ "${EKSCTL_OK}" == "true" && "${KUBECTL_OK}" == "true" ]]; then
  echo ""
  echo "  Both tools are installed. Nothing to do."
  echo "  To upgrade on Linux/macOS : sudo eksctl upgrade  |  sudo kubectl ..."
  echo "  To upgrade on Windows     : choco upgrade eksctl kubernetes-cli -y"
  echo ""
  exit 0
fi

# Detect OS and architecture
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
  Linux)              OS_NAME="linux"   ;;
  Darwin)             OS_NAME="darwin"  ;;
  MINGW*|MSYS*|CYGWIN*) OS_NAME="windows" ;;
  *)
    echo "[ERROR] Unsupported OS: ${OS}"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Windows (Git Bash) — install via Chocolatey
# ---------------------------------------------------------------------------
if [[ "${OS_NAME}" == "windows" ]]; then
  echo "[INFO] Windows detected — installing eksctl via Chocolatey..."

  # Locate choco.exe (Git Bash does not add Chocolatey to PATH by default)
  CHOCO_PATH=""
  for candidate in \
    "/c/ProgramData/chocolatey/bin/choco.exe" \
    "/c/ProgramData/chocolatey/choco.exe" \
    "$(command -v choco 2>/dev/null || true)"
  do
    if [[ -x "${candidate}" ]]; then
      CHOCO_PATH="${candidate}"
      break
    fi
  done

  if [[ -z "${CHOCO_PATH}" ]]; then
    echo "[ERROR] Chocolatey not found."
    echo ""
    echo "  Install Chocolatey first by running the following in an"
    echo "  elevated PowerShell (Run as Administrator):"
    echo ""
    echo "    Set-ExecutionPolicy Bypass -Scope Process -Force"
    echo "    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072"
    echo "    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    echo ""
    echo "  Then re-open Git Bash and run this script again."
    exit 1
  fi

  [[ "${EKSCTL_OK}" == "false" ]] && "${CHOCO_PATH}" install eksctl -y
  [[ "${KUBECTL_OK}" == "false" ]] && "${CHOCO_PATH}" install kubernetes-cli -y

  echo ""
  echo "[OK] eksctl + kubectl installed successfully."
  echo ""
  echo "  IMPORTANT: Open a new Git Bash window so the updated PATH takes effect,"
  echo "  then verify with:  eksctl version  &&  kubectl version --client"
  echo ""
  echo "=================================================="
  echo "  TOOLS READY"
  echo "=================================================="
  echo ""
  echo "  Also ensure these are installed and configured:"
  echo "    - AWS CLI v2   : aws --version"
  echo "    - AWS profile  : aws configure --profile sarowar-ostad"
  echo ""
  echo "  Next step: create EKS cluster:"
  echo "    eksctl create cluster -f labs/lab-02-eks/cluster-config.yaml"
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Linux / macOS — download binaries from official sources
# ---------------------------------------------------------------------------

# ── eksctl ─────────────────────────────────────────────────────────────────
if [[ "${EKSCTL_OK}" == "false" ]]; then
  EKSCTL_URL="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${OS_NAME}_${ARCH_NAME}.tar.gz"
  echo "[INFO] Downloading eksctl for ${OS_NAME}/${ARCH_NAME}..."
  curl -sL "${EKSCTL_URL}" | tar xz -C /tmp
  sudo mv /tmp/eksctl /usr/local/bin/eksctl
  sudo chmod +x /usr/local/bin/eksctl
  echo "[OK] eksctl installed: $(eksctl version)"
fi

# ── kubectl ─────────────────────────────────────────────────────────────────
if [[ "${KUBECTL_OK}" == "false" ]]; then
  echo "[INFO] Fetching latest stable kubectl version..."
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS_NAME}/${ARCH_NAME}/kubectl"
  echo "[INFO] Downloading kubectl ${KUBECTL_VERSION} for ${OS_NAME}/${ARCH_NAME}..."
  curl -fsSL -o /tmp/kubectl "${KUBECTL_URL}"
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
  sudo chmod +x /usr/local/bin/kubectl
  echo "[OK] kubectl installed: $(kubectl version --client 2>/dev/null | head -1)"
fi

echo ""
echo "=================================================="
echo "  TOOLS READY"
echo "=================================================="
echo ""
echo "  Also ensure these are installed and configured:"
echo "    - AWS CLI v2   : aws --version"
echo "    - AWS profile  : aws configure --profile sarowar-ostad"
echo ""
echo "  Next step: create EKS cluster:"
echo "    eksctl create cluster -f labs/lab-02-eks/cluster-config.yaml"
echo ""
