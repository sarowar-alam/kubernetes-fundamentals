# Master Node Setup — Manual Execution Guide

**Script companion:** `master-init.sh`  
**Run on:** Master Node only  
**Starting point:** Fresh Ubuntu 22.04 LTS server (nothing pre-installed)

---

## What You Will Do

```
STEP 0 → SSH into the fresh master server
STEP 1 → Clone the repo (or use one-liner)
STEP 2 → System Preparation  (swap, kernel, containerd, kubeadm)
STEP 3 → kubeadm init        (bootstrap control plane)
STEP 4 → Configure kubectl   (set up CLI access)
STEP 5 → Install Calico CNI  (enable pod networking)
STEP 6 → Get join command    (pass to worker nodes)
STEP 7 → Verify cluster      (full health check)
```

---

## Quick Start (Automated — 3 Commands)

SSH into your master server, then:

```bash
# Install git and clone the repo
sudo apt-get install -y git
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm

# Run the self-contained setup script
chmod +x master-init.sh
sudo ./master-init.sh
```

The script handles everything — apt update, swap, kernel, containerd, kubeadm, cluster init, CNI.  
**Total time: ~10 minutes.** Then skip to [STEP 6 — Get Join Command](#step-6--get-the-worker-join-command).

> **Alternatively — no git required (one-liner):**
> ```bash
> curl -fsSL https://raw.githubusercontent.com/sarowar-alam/kubernetes-fundamentals/main/labs/lab-01-kubeadm/master-init.sh | sudo bash
> ```

---

## Manual Step-by-Step

Follow this if you want to understand every command (recommended for learning).

---

## STEP 0 — SSH Into the Master Server

```bash
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<MASTER_PUBLIC_IP>
```

Confirm you are on the right machine:
```bash
hostname
# Expected: something like "ip-10-0-1-x" or "k8s-master"

uname -a
# Expected: Linux ... Ubuntu ...

lsb_release -a
# Expected: Ubuntu 22.04 LTS
```

---

## STEP 1 — Clone the Repository

```bash
# Install git (typically not on fresh Ubuntu)
sudo apt-get update -y
sudo apt-get install -y git

# Clone the course repository
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm
ls -la
```

**Expected files:**
```
master-init.sh
master-init-guide.md
worker-join.sh
worker-join-guide.md
```

---

## STEP 2 — System Preparation

### 2.1 Full system update

```bash
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release wget
```

### ✅ Verify
```bash
curl --version | head -1
# Expected: curl 7.x.x or 8.x.x
```

---

### 2.2 Disable swap

Kubernetes **requires** swap to be off. It relies on accurate memory reporting — swap breaks this.

```bash
# Turn off swap immediately (this session)
sudo swapoff -a

# Disable permanently (survives reboot) by commenting out swap in fstab
sudo sed -i '/\bswap\b/s/^/#/' /etc/fstab
```

### ✅ Verify
```bash
free -h | grep -i swap
# Expected:
# Swap:          0B         0B         0B

swapon --show
# Expected: (no output — means no swap active)
```

---

### 2.3 Load kernel modules

`overlay` — used by containerd for layered container filesystems  
`br_netfilter` — allows iptables to see bridged traffic (required by kube-proxy)

```bash
# Persist across reboots
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Load immediately (no reboot needed)
sudo modprobe overlay
sudo modprobe br_netfilter
```

### ✅ Verify
```bash
lsmod | grep -E 'overlay|br_netfilter'
# Expected: both modules listed
```

---

### 2.4 Configure kernel networking parameters

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply without reboot
sudo sysctl --system
```

### ✅ Verify
```bash
cat /proc/sys/net/ipv4/ip_forward
# Expected: 1

cat /proc/sys/net/bridge/bridge-nf-call-iptables
# Expected: 1
```

---

### 2.5 Install containerd

Kubernetes uses `containerd` as the container runtime (not Docker).

```bash
# Add Docker's GPG key (containerd is distributed by Docker)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y containerd.io
```

**Configure containerd to use systemd cgroup driver:**

```bash
# Generate default config
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Enable systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart to apply
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### ✅ Verify
```bash
sudo systemctl status containerd | grep -E 'Active|Loaded'
# Expected: Active: active (running)

grep SystemdCgroup /etc/containerd/config.toml
# Expected: SystemdCgroup = true
```

---

### 2.6 Install kubeadm, kubelet, kubectl

```bash
# Add Kubernetes apt repository (K8s 1.29)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl

# Pin versions — prevent accidental upgrade during apt upgrade
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable kubelet
```

### ✅ Verify
```bash
kubeadm version
# Expected: kubeadm version: &version.Info{GitVersion:"v1.29.x", ...}

kubectl version --client
# Expected: Client Version: v1.29.x

sudo systemctl is-enabled kubelet
# Expected: enabled
```

---

## STEP 3 — Initialize the Control Plane

### 3.1 Get the master's private IP

```bash
MASTER_PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo "Master private IP: ${MASTER_PRIVATE_IP}"
```

**Expected:** A `10.0.x.x` IP (your VPC private IP).  
> Always use the **private IP** — not the public IP. The private IP is stable within the VPC.

---

### 3.2 Run kubeadm init

```bash
sudo kubeadm init \
  --apiserver-advertise-address=${MASTER_PRIVATE_IP} \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=1.29.0 \
  --ignore-preflight-errors=NumCPU \
  | tee /tmp/kubeadm-init.log
```

**Flag reference:**

| Flag | Why it's there |
|---|---|
| `--apiserver-advertise-address` | IP worker nodes use to reach the API server |
| `--pod-network-cidr=192.168.0.0/16` | Pod IP range — must match Calico's default |
| `--kubernetes-version=1.29.0` | Pin version, no surprises |
| `--ignore-preflight-errors=NumCPU` | t3.medium has 2 vCPU; K8s warns but works fine |
| `tee /tmp/kubeadm-init.log` | Saves output — join command is at the bottom |

**This takes 2–3 minutes.** Expected final lines:
```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

...

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 10.0.1.x:6443 --token abcdef.1234567890abcdef \
        --discovery-token-ca-cert-hash sha256:abc123...
```

**Copy and save the `kubeadm join` line** — you need it for STEP 6.

---

## STEP 4 — Configure kubectl

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### ✅ Verify
```bash
kubectl get nodes
```

Expected (`NotReady` is normal — CNI not installed yet):
```
NAME         STATUS     ROLES           AGE   VERSION
k8s-master   NotReady   control-plane   1m    v1.29.0
```

```bash
kubectl cluster-info
# Expected: Kubernetes control plane is running at https://10.0.1.x:6443
```

---

## STEP 5 — Install Calico CNI

Pods cannot communicate without a CNI plugin. Calico provides the pod network using `192.168.0.0/16`.

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

**Expected output:** Several lines ending with `created`.

### ✅ Verify — Wait for Calico pods to be Running (~60 seconds)

```bash
watch kubectl get pods -n kube-system
```

Wait until every `calico-*` pod shows `1/1 Running`. Press `Ctrl+C`.

```
NAME                                       READY   STATUS    AGE
calico-kube-controllers-xxx                1/1     Running   60s
calico-node-xxxxx                          1/1     Running   60s
coredns-xxx                                1/1     Running   3m
etcd-k8s-master                            1/1     Running   3m
kube-apiserver-k8s-master                  1/1     Running   3m
kube-controller-manager-k8s-master         1/1     Running   3m
kube-proxy-xxxxx                           1/1     Running   3m
kube-scheduler-k8s-master                  1/1     Running   3m
```

```bash
kubectl get nodes
# Expected: STATUS = Ready
```

```
NAME         STATUS   ROLES           AGE   VERSION
k8s-master   Ready    control-plane   5m    v1.29.0
```

---

## STEP 6 — Get the Worker Join Command

```bash
# Option A: Read from saved log (valid for 24h from init)
grep "kubeadm join" /tmp/kubeadm-init.log

# Option B: Generate a fresh token (use this after 24h or if token lost)
sudo kubeadm token create --print-join-command
```

**Example output:**
```
kubeadm join 10.0.1.12:6443 --token abcdef.1234567890abcdef \
        --discovery-token-ca-cert-hash sha256:abc123def456...
```

Share this with students. They will use it in `worker-join-guide.md`.

---

## STEP 7 — Full Cluster Health Check

Run these **after both workers have joined** (see `worker-join-guide.md`):

### 7.1 All nodes Ready
```bash
kubectl get nodes -o wide
```

```
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP
k8s-master     Ready    control-plane   10m   v1.29.0   10.0.1.x
k8s-worker-1   Ready    <none>          3m    v1.29.0   10.0.1.x
k8s-worker-2   Ready    <none>          2m    v1.29.0   10.0.1.x
```

### 7.2 All system pods healthy
```bash
kubectl get pods -n kube-system
# All pods: Running. None in CrashLoopBackOff or Pending.
```

### 7.3 Control plane components
```bash
kubectl get componentstatuses
```

```
NAME                 STATUS    MESSAGE
controller-manager   Healthy   ok
scheduler            Healthy   ok
etcd-0               Healthy   ok
```

### 7.4 Test scheduling on workers
```bash
kubectl create deployment verify --image=nginx:alpine --replicas=2
kubectl get pods -o wide
# Pods should land on k8s-worker-1 and k8s-worker-2 (not master)
```

Clean up:
```bash
kubectl delete deployment verify
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `kubeadm init` fails: `swap is enabled` | Swap not disabled | `sudo swapoff -a` then retry |
| `kubeadm init` fails: `port 6443 in use` | Previous cluster exists | `sudo kubeadm reset -f` then retry |
| `kubectl`: `connection refused` | kubeconfig not copied | Re-run the 3 copy commands in STEP 4 |
| Master stays `NotReady` after 3 min | Calico pending | `kubectl get pods -n kube-system` — check for errors |
| Calico pods stuck in `Init` | Slow image pull | Wait 2 min; check internet: `curl -I https://docker.io` |
| `journalctl -u kubelet` shows errors | containerd not running | `sudo systemctl restart containerd` |
| Token expired on worker join | Tokens last 24h | Re-run on master: `sudo kubeadm token create --print-join-command` |

