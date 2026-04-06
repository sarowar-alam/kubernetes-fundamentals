#!/usr/bin/env bash
# =============================================================================
# worker-join.sh
# Run on each Worker Node AFTER master-init.sh has completed.
#
# Usage:
#   1. Edit the JOIN_TOKEN, JOIN_HASH, and MASTER_IP variables below
#      (copy values from the kubeadm init output on the master)
#   2. chmod +x worker-join.sh
#   3. sudo ./worker-join.sh
#
# OR pass variables inline:
#   sudo MASTER_IP=10.0.1.x JOIN_TOKEN=abcdef.1234 JOIN_HASH=sha256:abc ./worker-join.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# FILL THESE IN FROM THE MASTER NODE'S kubeadm init OUTPUT
# ---------------------------------------------------------------------------
MASTER_IP="${MASTER_IP:-}"            # e.g., 10.0.1.12    (private IP of master)
JOIN_TOKEN="${JOIN_TOKEN:-}"          # e.g., abcdef.1234567890abcdef
JOIN_HASH="${JOIN_HASH:-}"            # e.g., sha256:abc123...

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if [[ -z "${MASTER_IP}" || -z "${JOIN_TOKEN}" || -z "${JOIN_HASH}" ]]; then
  echo "[ERROR] Missing required values."
  echo ""
  echo "  Set them by editing this script, OR run with inline variables:"
  echo ""
  echo "  sudo MASTER_IP=10.0.1.x \\"
  echo "       JOIN_TOKEN=abcdef.1234567890abcdef \\"
  echo "       JOIN_HASH=sha256:abc123... \\"
  echo "       ./worker-join.sh"
  echo ""
  echo "  Find these values in the output of 'kubeadm init' on the master."
  echo "  Or regenerate with: kubeadm token create --print-join-command"
  exit 1
fi

# Must run as root
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (sudo ./worker-join.sh)"
  exit 1
fi

echo "=================================================="
echo "  Joining worker node to Kubernetes cluster"
echo "  Master: ${MASTER_IP}:6443"
echo "=================================================="
echo ""

# ---------------------------------------------------------------------------
# Join the cluster
# ---------------------------------------------------------------------------
kubeadm join "${MASTER_IP}:6443" \
  --token                     "${JOIN_TOKEN}" \
  --discovery-token-ca-cert-hash "${JOIN_HASH}"

echo ""
echo "=================================================="
echo "  WORKER NODE JOINED"
echo "=================================================="
echo ""
echo "  Verify from the master node:"
echo "  kubectl get nodes"
echo ""
echo "  This node should appear as 'Ready' within 30-60 seconds."
echo "=================================================="
