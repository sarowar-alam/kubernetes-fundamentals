#!/usr/bin/env bash
# =============================================================================
# install-eksctl.sh
# Downloads and installs the latest eksctl binary on Linux/macOS/Windows.
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
# Tested on: Ubuntu 22.04 | macOS 13+ | Windows 11 Git Bash
# Windows requirement: Chocolatey must be installed (https://chocolatey.org)
# =============================================================================

set -euo pipefail

echo "=================================================="
echo "  Installing eksctl"
echo "=================================================="

# ---------------------------------------------------------------------------
# Early-exit guard: skip install if eksctl is already present
# ---------------------------------------------------------------------------
if command -v eksctl &>/dev/null; then
  echo "[OK] eksctl is already installed: $(eksctl version)"
  echo ""
  echo "  To upgrade on Linux/macOS : sudo eksctl upgrade"
  echo "  To upgrade on Windows     : choco upgrade eksctl -y"
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

  "${CHOCO_PATH}" install eksctl -y

  echo ""
  echo "[OK] eksctl installed successfully."
  echo ""
  echo "  IMPORTANT: Open a new Git Bash window so the updated PATH takes effect,"
  echo "  then verify with: eksctl version"
  echo ""
  echo "=================================================="
  echo "  EKSCTL READY"
  echo "=================================================="
  echo ""
  echo "  Also ensure these are installed and configured:"
  echo "    - AWS CLI v2   : aws --version"
  echo "    - kubectl      : kubectl version --client"
  echo "    - AWS profile  : aws configure --profile sarowar-ostad"
  echo ""
  echo "  Next step: create EKS cluster:"
  echo "    eksctl create cluster -f labs/lab-02-eks/cluster-config.yaml"
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Linux / macOS — download binary from GitHub Releases
# ---------------------------------------------------------------------------
DOWNLOAD_URL="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${OS_NAME}_${ARCH_NAME}.tar.gz"

echo "[INFO] Downloading eksctl for ${OS_NAME}/${ARCH_NAME}..."
curl -sL "${DOWNLOAD_URL}" | tar xz -C /tmp

echo "[INFO] Moving eksctl to /usr/local/bin..."
sudo mv /tmp/eksctl /usr/local/bin/eksctl
sudo chmod +x /usr/local/bin/eksctl

echo ""
echo "[OK] eksctl installed: $(eksctl version)"

echo ""
echo "=================================================="
echo "  EKSCTL READY"
echo "=================================================="
echo ""
echo "  Also ensure these are installed and configured:"
echo "    - AWS CLI v2   : aws --version"
echo "    - kubectl      : kubectl version --client"
echo "    - AWS profile  : aws configure --profile sarowar-ostad"
echo ""
echo "  Next step: create EKS cluster:"
echo "    eksctl create cluster -f labs/lab-02-eks/cluster-config.yaml"
echo ""
