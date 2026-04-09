#!/usr/bin/env bash
# =============================================================================
# master-init.sh
# Self-contained Kubernetes Master Node setup — runs on a FRESH Ubuntu 22.04
#
# Handles EVERYTHING in two phases:
#   Phase 1 — System Preparation
#     1. apt update + upgrade
#     2. Disable swap
#     3. Load kernel modules (overlay, br_netfilter)
#     4. Configure kernel networking parameters
#     5. Install containerd (container runtime)
#     6. Install kubeadm, kubelet, kubectl
#     7. Pre-flight verification
#
#   Phase 2 — Cluster Bootstrap
#     8.  kubeadm init
#     9.  Configure kubectl for ubuntu user
#    10.  Install Calico CNI
#    11.  Generate and display worker join command
#
# Every step checks if already done — safe to re-run (idempotent).
#
# Usage — from a FRESH Ubuntu 22.04 server:
#
#   Option A — Clone the repo, then run:
#     sudo apt-get install -y git
#     git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
#     cd kubernetes-fundamentals/labs/lab-01-kubeadm
#     chmod +x master-init.sh
#     sudo ./master-init.sh
#
#   Option B — One-liner (no git required):
#     curl -fsSL https://raw.githubusercontent.com/sarowar-alam/kubernetes-fundamentals/main/labs/lab-01-kubeadm/master-init.sh | sudo bash
#
# Requirements: Ubuntu 22.04 LTS | 2+ vCPU | 4+ GB RAM | internet access
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${BOLD}${BLUE}──────────────────────────────────────────────────${NC}";
          echo -e "${BOLD}  $*${NC}";
          echo -e "${BOLD}${BLUE}──────────────────────────────────────────────────${NC}"; }

K8S_VERSION="1.29"
K8S_FULL_VERSION="1.29.0"
CALICO_VERSION="v3.27.0"
UBUNTU_HOME="/home/ubuntu"

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
[[ "${EUID}" -ne 0 ]] && { err "Run as root:  sudo ./master-init.sh"; exit 1; }
grep -qi "ubuntu" /etc/os-release 2>/dev/null \
  || { err "This script requires Ubuntu 22.04 LTS."; exit 1; }

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Kubernetes Master Node — Full Setup Script         ║${NC}"
echo -e "${GREEN}${BOLD}║   K8s ${K8S_VERSION} | containerd | Calico ${CALICO_VERSION}         ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

# =============================================================================
# PHASE 1 — SYSTEM PREPARATION
# =============================================================================
step "PHASE 1/2 — System Preparation"

# ── 1. Update packages ────────────────────────────────────────────────────────
info "[1/7] Updating system packages..."
apt-get update -y -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release wget git
ok "System updated and base packages installed."

# ── 2. Disable swap ───────────────────────────────────────────────────────────
info "[2/7] Checking swap..."
if swapon --show 2>/dev/null | grep -q .; then
  swapoff -a
  ok "Swap deactivated for this session."
else
  ok "Swap already inactive."
fi
# Make permanent: disable swap entries in /etc/fstab
if grep -qE '^\s*[^#].*\bswap\b' /etc/fstab 2>/dev/null; then
  sed -i '/\bswap\b/s/^/#/' /etc/fstab
  ok "Swap entry commented out in /etc/fstab (persistent across reboots)."
else
  ok "No active swap entries in /etc/fstab."
fi

# ── 3. Kernel modules ─────────────────────────────────────────────────────────
info "[3/7] Loading kernel modules (overlay, br_netfilter)..."
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
for mod in overlay br_netfilter; do
  if ! lsmod | grep -q "^${mod}"; then
    modprobe "${mod}"
    ok "Module loaded: ${mod}"
  else
    ok "Module already loaded: ${mod}"
  fi
done

# ── 4. Kernel networking parameters ──────────────────────────────────────────
info "[4/7] Configuring kernel networking parameters..."
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] \
  && ok "ip_forward = 1 confirmed." \
  || { err "ip_forward is not 1. Check sysctl config."; exit 1; }

# ── 5. Install containerd ─────────────────────────────────────────────────────
info "[5/7] Checking containerd..."
if ! command -v containerd &>/dev/null; then
  info "containerd not found — installing..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -y -qq
  apt-get install -y -qq containerd.io
  ok "containerd installed."
else
  ok "containerd already installed: $(containerd --version | awk '{print $3}')"
fi
# Configure systemd cgroup driver if not already set
if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
  info "Configuring containerd (systemd cgroup driver)..."
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  ok "containerd configured with systemd cgroup driver."
else
  ok "containerd already configured with systemd cgroup driver."
fi
systemctl enable containerd -q
ok "containerd: $(systemctl is-active containerd)"

# ── 6. Install kubeadm, kubelet, kubectl ─────────────────────────────────────
info "[6/7] Checking kubeadm / kubelet / kubectl..."
if ! command -v kubeadm &>/dev/null; then
  info "Installing Kubernetes ${K8S_VERSION} tooling..."
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  apt-get update -y -qq
  apt-get install -y kubelet kubeadm kubectl
  # Pin versions — prevent accidental upgrade during apt upgrade
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet -q
  ok "kubeadm, kubelet, kubectl installed (version-pinned to ${K8S_VERSION})."
else
  ok "kubeadm already installed: $(kubeadm version --output short 2>/dev/null || echo 'installed')"
fi

# ── 7. Pre-flight verification ────────────────────────────────────────────────
info "[7/7] Running pre-flight checks..."
[[ "$(swapon --show 2>/dev/null | wc -l)" -eq 0 ]] \
  && ok "Swap               : OFF" \
  || { err "Swap is still active! Cannot continue."; exit 1; }
ok "containerd         : $(systemctl is-active containerd)"
ok "kubelet            : enabled (activates after kubeadm init)"
ok "kubeadm            : $(kubeadm version --output short 2>/dev/null)"
ok "kubectl            : $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

# =============================================================================
# PHASE 2 — CLUSTER BOOTSTRAP
# =============================================================================
step "PHASE 2/2 — Kubernetes Cluster Bootstrap"

# ── 8. kubeadm init ───────────────────────────────────────────────────────────
info "[8/11] Checking if control plane is already initialized..."
if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
  warn "Control plane is already initialized on this node. Skipping kubeadm init."
  warn "To reinitialize from scratch: sudo kubeadm reset -f && sudo ./master-init.sh"
else
  MASTER_PRIVATE_IP=$(hostname -I | awk '{print $1}')
  info "Master Private IP : ${MASTER_PRIVATE_IP}"
  info "Pod Network CIDR  : 192.168.0.0/16 (required by Calico)"
  info "Running kubeadm init — this takes 2-3 minutes..."
  echo ""
  # --node-name: use NODE_NAME env var if set (injected by provision-k8s-cluster.sh user data)
  k8s_init_args=()
  [[ -n "${NODE_NAME:-}" ]] && k8s_init_args+=(--node-name="${NODE_NAME}")
  kubeadm init \
    "${k8s_init_args[@]}" \
    --apiserver-advertise-address="${MASTER_PRIVATE_IP}" \
    --pod-network-cidr=192.168.0.0/16 \
    --kubernetes-version="${K8S_FULL_VERSION}" \
    --ignore-preflight-errors=NumCPU \
    | tee /tmp/kubeadm-init.log
  ok "kubeadm init complete."
fi

# ── 9. Configure kubectl ──────────────────────────────────────────────────────
info "[9/11] Configuring kubectl for users: ubuntu + root..."
# ubuntu user (standard interactive sessions)
mkdir -p "${UBUNTU_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${UBUNTU_HOME}/.kube/config"
chown -R ubuntu:ubuntu "${UBUNTU_HOME}/.kube"
# root user (SSM sessions start as root by default)
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
# Also export for this running script session
export KUBECONFIG=/etc/kubernetes/admin.conf
ok "kubectl configured (~/.kube/config ready for ubuntu + root)."

# ── 10. Calico CNI ────────────────────────────────────────────────────────────
info "[10/11] Checking Calico CNI..."
if kubectl get daemonset calico-node -n kube-system &>/dev/null 2>&1; then
  ok "Calico already installed. Skipping."
else
  info "Installing Calico ${CALICO_VERSION}..."
  kubectl apply -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  ok "Calico applied. Pods are starting in kube-system namespace."
fi

# ── 11. Generate join command ─────────────────────────────────────────────────
info "[11/11] Generating worker join command..."
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
echo "${JOIN_CMD}" > /tmp/worker-join-command.txt
chmod 644 /tmp/worker-join-command.txt
ok "Join command saved to /tmp/worker-join-command.txt"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║              MASTER NODE SETUP COMPLETE              ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  ► Wait ~60s for Calico pods, then verify:${NC}"
echo -e "    kubectl get nodes"
echo -e "    kubectl get pods -n kube-system"
echo ""
echo -e "${YELLOW}  ► Worker Join Command  (also saved to /tmp/worker-join-command.txt):${NC}"
echo ""
echo -e "${GREEN}    sudo ${JOIN_CMD}${NC}"
echo ""
echo -e "${YELLOW}  ► Next step — on each worker node:${NC}"
echo -e "    sudo apt-get install -y git"
echo -e "    git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git"
echo -e "    cd kubernetes-fundamentals/labs/lab-01-kubeadm"
echo -e "    chmod +x worker-join.sh && sudo ./worker-join.sh"
echo ""
