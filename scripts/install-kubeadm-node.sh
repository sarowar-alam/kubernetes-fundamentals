#!/usr/bin/env bash
# =============================================================================
# install-kubeadm-node.sh
# Run this on EVERY node (master AND workers) before running kubeadm.
#
# What this script does:
#   1. Updates the OS
#   2. Disables swap (required by Kubernetes)
#   3. Loads required kernel modules
#   4. Sets kernel networking parameters
#   5. Installs containerd (container runtime)
#   6. Installs kubeadm, kubelet, kubectl
#
# Usage:
#   Copy this file to each node, then:
#     chmod +x install-kubeadm-node.sh
#     sudo ./install-kubeadm-node.sh
#
# Tested on: Ubuntu 22.04 LTS
# Kubernetes version: 1.29
# =============================================================================

set -euo pipefail

K8S_VERSION="1.29"

echo "=================================================="
echo "  Kubernetes Node Preparation Script"
echo "  Target: Ubuntu 22.04 LTS"
echo "  K8s Version: ${K8S_VERSION}"
echo "=================================================="

# Must run as root
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (or with sudo)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Update system packages
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 1] Updating system packages..."
apt-get update -y
apt-get upgrade -y
echo "[OK] System updated."

# ---------------------------------------------------------------------------
# Step 2: Disable swap
# WHY: Kubernetes does not work properly with swap enabled.
#      It relies on accurate memory reporting. Swap makes this unreliable.
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 2] Disabling swap..."
swapoff -a
# Remove swap entry from fstab so it stays disabled after reboot
sed -i '/ swap / s/^/#/' /etc/fstab
echo "[OK] Swap disabled."

# ---------------------------------------------------------------------------
# Step 3: Load required kernel modules
# WHY:
#   overlay     - used by containerd for layered container filesystem
#   br_netfilter - allows iptables to see bridged traffic (needed by kube-proxy)
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 3] Loading kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
echo "[OK] Kernel modules loaded."

# ---------------------------------------------------------------------------
# Step 4: Set kernel networking parameters
# WHY:
#   net.bridge.bridge-nf-call-iptables  = 1
#     → iptables sees bridged IPv4 traffic (required for pod networking)
#   net.bridge.bridge-nf-call-ip6tables = 1
#     → same, for IPv6
#   net.ipv4.ip_forward                 = 1
#     → allows routing between pods and to the outside world
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 4] Configuring kernel networking parameters..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply immediately without reboot
sysctl --system
echo "[OK] Kernel parameters configured."

# ---------------------------------------------------------------------------
# Step 5: Install containerd (container runtime)
# WHY: Kubernetes uses containerd to run containers. Docker is not required.
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 5] Installing containerd..."

# Install prerequisites
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key (containerd is distributed by Docker)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y containerd.io

# ---------------------------------------------------------------------------
# Configure containerd to use systemd cgroup driver
# WHY: Kubernetes recommends systemd as the cgroup driver for stability.
#      The default containerd config uses cgroupfs which can conflict.
# ---------------------------------------------------------------------------
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Enable systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
echo "[OK] containerd installed and configured."

# ---------------------------------------------------------------------------
# Step 6: Install kubeadm, kubelet, kubectl
# WHY:
#   kubeadm  - tool to bootstrap the cluster (init, join)
#   kubelet  - agent that runs on this node; manages containers
#   kubectl  - CLI to interact with the cluster (install on master; optional on workers)
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 6] Installing kubeadm, kubelet, kubectl..."

# Add Kubernetes apt repository
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl

# Pin the versions so they don't get accidentally upgraded
apt-mark hold kubelet kubeadm kubectl

# Enable kubelet — it will start fully only after kubeadm init/join
systemctl enable kubelet
echo "[OK] kubeadm, kubelet, kubectl installed and pinned."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=================================================="
echo "  NODE PREPARATION COMPLETE"
echo "=================================================="
echo ""
echo "  Versions installed:"
echo "    $(kubeadm version --output short)"
echo "    $(kubectl version --client --output yaml | grep gitVersion | head -1)"
echo "    containerd: $(containerd --version)"
echo ""
echo "  Next steps:"
echo "    ON MASTER NODE ONLY: run  labs/lab-01-kubeadm/master-init.sh"
echo "    ON WORKER NODES    : run  labs/lab-01-kubeadm/worker-join.sh  (after master init)"
echo ""
