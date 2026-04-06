#!/usr/bin/env bash
# =============================================================================
# worker-join.sh
# Self-contained Kubernetes Worker Node setup — runs on a FRESH Ubuntu 22.04
#
# Handles EVERYTHING in two phases:
#   Phase 1 — System Preparation  (identical to master-init.sh Phase 1)
#     1. apt update + upgrade
#     2. Disable swap
#     3. Load kernel modules
#     4. Configure kernel networking parameters
#     5. Install containerd
#     6. Install kubeadm, kubelet, kubectl
#     7. Pre-flight verification + connectivity check to master
#
#   Phase 2 — Join the Cluster
#     8.  Collect join parameters (interactive prompt or env vars)
#     9.  kubeadm join
#
# Every step checks if already done — safe to re-run (idempotent).
#
# Usage — from a FRESH Ubuntu 22.04 server:
#
#   Option A — Clone the repo, then run interactively:
#     sudo apt-get install -y git
#     git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
#     cd kubernetes-fundamentals/labs/lab-01-kubeadm
#     chmod +x worker-join.sh
#     sudo ./worker-join.sh
#     # Script will prompt for Master IP, Token, and Hash
#
#   Option B — Pass join values as environment variables (non-interactive):
#     sudo MASTER_IP=10.0.1.x \
#          JOIN_TOKEN=abcdef.1234567890abcdef \
#          JOIN_HASH=sha256:abc123... \
#          ./worker-join.sh
#
#   Option C — One-liner with values (no git required):
#     curl -fsSL https://raw.githubusercontent.com/sarowar-alam/kubernetes-fundamentals/main/labs/lab-01-kubeadm/worker-join.sh \
#       | sudo MASTER_IP=10.0.1.x JOIN_TOKEN=abc.def JOIN_HASH=sha256:xxx bash
#
#   Get the join command from the master node at any time:
#     sudo kubeadm token create --print-join-command
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
CALICO_VERSION="v3.27.0"

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
[[ "${EUID}" -ne 0 ]] && { err "Run as root:  sudo ./worker-join.sh"; exit 1; }
grep -qi "ubuntu" /etc/os-release 2>/dev/null \
  || { err "This script requires Ubuntu 22.04 LTS."; exit 1; }

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Kubernetes Worker Node — Full Setup Script         ║${NC}"
echo -e "${GREEN}${BOLD}║   K8s ${K8S_VERSION} | containerd | Calico ${CALICO_VERSION}         ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

# =============================================================================
# PHASE 1 — SYSTEM PREPARATION  (identical to master-init.sh Phase 1)
# =============================================================================
step "PHASE 1/2 — System Preparation"

# ── 1. Update packages ────────────────────────────────────────────────────────
info "[1/7] Updating system packages..."
apt-get update -y -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg \
  lsb-release wget git netcat-openbsd
ok "System updated and base packages installed."

# ── 2. Disable swap ───────────────────────────────────────────────────────────
info "[2/7] Checking swap..."
if swapon --show 2>/dev/null | grep -q .; then
  swapoff -a
  ok "Swap deactivated for this session."
else
  ok "Swap already inactive."
fi
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
ok "kubelet            : enabled"
ok "kubeadm            : $(kubeadm version --output short 2>/dev/null || echo 'installed')"

# =============================================================================
# PHASE 2 — JOIN THE CLUSTER
# =============================================================================
step "PHASE 2/2 — Join the Kubernetes Cluster"

# ── Collect join parameters ───────────────────────────────────────────────────
MASTER_IP="${MASTER_IP:-}"
JOIN_TOKEN="${JOIN_TOKEN:-}"
JOIN_HASH="${JOIN_HASH:-}"

if [[ -z "${MASTER_IP}" ]]; then
  echo ""
  echo -e "${YELLOW}  Enter the values from the master node output.${NC}"
  echo -e "  (On master, run:  sudo kubeadm token create --print-join-command)"
  echo ""
  read -rp "  Master Private IP   (e.g. 10.0.1.12)             : " MASTER_IP
  read -rp "  Join Token          (e.g. abcdef.1234567890abcdef): " JOIN_TOKEN
  read -rp "  Discovery CA Hash   (e.g. sha256:abc123...)       : " JOIN_HASH
  echo ""
fi

[[ -z "${MASTER_IP}" || -z "${JOIN_TOKEN}" || -z "${JOIN_HASH}" ]] && {
  err "MASTER_IP, JOIN_TOKEN, and JOIN_HASH are all required."
  exit 1
}

# ── Connectivity check ────────────────────────────────────────────────────────
info "Checking connectivity to master API server (${MASTER_IP}:6443)..."
if nc -zw5 "${MASTER_IP}" 6443 2>/dev/null; then
  ok "Master API server is reachable at ${MASTER_IP}:6443"
else
  err "Cannot reach ${MASTER_IP}:6443"
  err "Check: Is the master running? Is port 6443 open in the AWS Security Group?"
  exit 1
fi

# ── Check if already joined ───────────────────────────────────────────────────
if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  warn "This node appears to have already joined a cluster."
  warn "To re-join: sudo kubeadm reset -f && sudo ./worker-join.sh"
  exit 0
fi

# ── Run kubeadm join ──────────────────────────────────────────────────────────
info "Joining the Kubernetes cluster..."
echo ""
kubeadm join "${MASTER_IP}:6443" \
  --token                        "${JOIN_TOKEN}" \
  --discovery-token-ca-cert-hash "${JOIN_HASH}"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║              WORKER NODE JOINED                      ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  ► Verify from the MASTER node:${NC}"
echo -e "    kubectl get nodes"
echo -e "    kubectl get nodes -w    (watch — this node shows Ready in ~60s)"
echo ""
