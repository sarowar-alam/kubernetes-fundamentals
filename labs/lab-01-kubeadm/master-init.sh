#!/usr/bin/env bash
# =============================================================================
# master-init.sh
# Run ONLY on the Master Node after install-kubeadm-node.sh has completed.
#
# What this does:
#   1. Initializes the Kubernetes control plane (kubeadm init)
#   2. Sets up kubectl config for ubuntu user
#   3. Installs Calico CNI for pod networking
#   4. Prints the join command for workers
#
# Usage:
#   chmod +x master-init.sh
#   sudo ./master-init.sh
#
# After this script finishes:
#   - Run worker-join.sh on each worker node
# =============================================================================

set -euo pipefail

# Must run as root
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (sudo ./master-init.sh)"
  exit 1
fi

# Get the private IP of this node
# This is the IP that worker nodes will use to reach the API server
MASTER_PRIVATE_IP=$(hostname -I | awk '{print $1}')

echo "=================================================="
echo "  Kubernetes Master Node Initialization"
echo "  Master Private IP: ${MASTER_PRIVATE_IP}"
echo "=================================================="

# ---------------------------------------------------------------------------
# Step 1: Initialize the control plane
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 1] Running kubeadm init..."
echo "         This will take 2-3 minutes..."

kubeadm init \
  --apiserver-advertise-address="${MASTER_PRIVATE_IP}" \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=1.29.0 \
  --ignore-preflight-errors=NumCPU \
  | tee /tmp/kubeadm-init.log

echo "[OK] kubeadm init complete."

# ---------------------------------------------------------------------------
# Step 2: Configure kubectl for the ubuntu user
# WHY: kubeadm writes the admin config to /etc/kubernetes/admin.conf
#      But kubectl reads from ~/.kube/config (under your home directory)
#      We copy it there so you don't need sudo for every kubectl command
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 2] Configuring kubectl for ubuntu user..."

UBUNTU_HOME="/home/ubuntu"
mkdir -p "${UBUNTU_HOME}/.kube"
cp -i /etc/kubernetes/admin.conf "${UBUNTU_HOME}/.kube/config"
chown -R ubuntu:ubuntu "${UBUNTU_HOME}/.kube"

echo "[OK] kubectl configured for user: ubuntu"

# ---------------------------------------------------------------------------
# Step 3: Install Calico CNI
# WHY: Pods cannot communicate without a CNI plugin.
#      Calico uses 192.168.0.0/16 which we specified in --pod-network-cidr
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 3] Installing Calico CNI..."
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl apply -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

echo "[OK] Calico applied. Pods will start in kube-system namespace."
echo "     Wait ~60 seconds for Calico pods to become Running before joining workers."

# ---------------------------------------------------------------------------
# Step 4: Extract and display the join command
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 4] Extracting join command for worker nodes..."

JOIN_CMD=$(tail -3 /tmp/kubeadm-init.log | tr -d '\\\n' | sed 's/kubeadm join/kubeadm join/g')

echo ""
echo "=================================================="
echo "  MASTER NODE READY"
echo "=================================================="
echo ""
echo "  Run this on EACH WORKER NODE:"
echo ""
echo "  sudo ${JOIN_CMD}"
echo ""
echo "  Or generate a new token anytime with:"
echo "  kubeadm token create --print-join-command"
echo ""
echo "  Verify cluster health:"
echo "  kubectl get nodes"
echo "  kubectl get pods -n kube-system"
echo ""
echo "  (Wait ~60 seconds for Calico pods to be Running before joining workers)"
echo "=================================================="
