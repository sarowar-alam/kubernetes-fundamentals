# Worker Node Join — Manual Execution Guide

**Companion to:** `worker-join.sh`  
**Applies to:** Each Worker Node (k8s-worker-1 AND k8s-worker-2)  
**Starting point:** Fresh Ubuntu 22.04 LTS server — no prerequisites required  
**Master node must be:** Running and `Ready` (complete `master-init-guide.md` first)

---

## Quick Start

If you just want to run the script and be done:

```bash
# On each worker node — run as the ubuntu user
sudo apt install -y git
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm

sudo ./worker-join.sh
# The script will prompt you for: MASTER_IP, JOIN_TOKEN, JOIN_HASH
```

The script handles **everything**: apt update, swap disable, kernel modules, sysctl, containerd, kubeadm, and the `kubeadm join` itself.

**This guide explains what `worker-join.sh` does and how to run each step manually.**

---

## STEP 0 — SSH into the Worker Node

```bash
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<WORKER_PUBLIC_IP>
```

Replace `<WORKER_PUBLIC_IP>` with the EC2 public IP of **k8s-worker-1** (or k8s-worker-2).

Confirm hostname and OS:
```bash
hostname
# Expected: k8s-worker-1  (or k8s-worker-2)

lsb_release -a
# Expected: Ubuntu 22.04 LTS
```

> If the hostname is wrong, set it now:
> ```bash
> sudo hostnamectl set-hostname k8s-worker-1
> ```

---

## STEP 1 — Clone the Repository

Install git and pull the lab scripts:

```bash
sudo apt update
sudo apt install -y git
```

```bash
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm
ls
```

**Expected output:**
```
master-init-guide.md  master-init.sh
worker-join-guide.md  worker-join.sh
```

---

## STEP 2 — Full System Preparation

This section prepares a **fresh Ubuntu 22.04** server to run Kubernetes. All substeps are idempotent — safe to re-run.

---

### STEP 2.1 — Update and Upgrade the System

```bash
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release wget git netcat-openbsd
```

**Why each package:**

| Package | Purpose |
|---|---|
| `apt-transport-https` | Allows `apt` to fetch packages over HTTPS (required for the Kubernetes and Docker repos) |
| `ca-certificates` | Trusts HTTPS certificates from those repos |
| `curl` | Downloads GPG keys and install scripts |
| `gnupg` | Verifies GPG signatures on repo keys |
| `lsb-release` | Identifies the Ubuntu version — used in the apt source string |
| `wget` | Alternative downloader used by some tooling |
| `git` | Clones this repository on the server |
| `netcat-openbsd` | Used by the `nc -zw5` connectivity check to verify the worker can reach the master API server on port 6443 before attempting `kubeadm join` |

`DEBIAN_FRONTEND=noninteractive` suppresses interactive prompts (e.g. service restart dialogs) so the upgrade never blocks the script.

### ✅ Verify 2.1
```bash
curl --version | head -1
# Expected: curl 7.x.x or 8.x.x
nc -h 2>&1 | head -1
# Expected: OpenBSD netcat ...
```

---

### STEP 2.2 — Disable Swap

Kubernetes **requires** swap to be completely off. Memory management must be handled by Kubernetes, not the OS swap subsystem.

```bash
sudo swapoff -a
```

Make it permanent (survives reboots):
```bash
sudo sed -i '/\bswap\b/s/^/#/' /etc/fstab
```

> This comments the swap line out with `#` rather than deleting it, which is the safer approach — the original entry is preserved and easy to reverse.

### ✅ Verify 2.2
```bash
free -h | grep Swap
# Expected:
# Swap:          0B         0B         0B

grep -i swap /etc/fstab
# Expected: (no output — all swap lines removed)
```

---

### STEP 2.3 — Load Required Kernel Modules

Kubernetes networking needs two kernel modules loaded:

| Module | Purpose |
|---|---|
| `overlay` | Used by containerd for layered container filesystems |
| `br_netfilter` | Allows iptables to see bridged network traffic (required for pod networking) |

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### ✅ Verify 2.3
```bash
lsmod | grep -E "overlay|br_netfilter"
# Expected (two lines):
# br_netfilter          xxxxx  0
# overlay               xxxxx  0
```

---

### STEP 2.4 — Apply sysctl Network Settings

These three kernel parameters are required for Kubernetes networking to function correctly:

| Parameter | Why it is required |
|---|---|
| `net.bridge.bridge-nf-call-iptables = 1` | Makes iptables see traffic crossing Linux bridges. Without this, kube-proxy rules are bypassed and pod-to-service routing breaks. |
| `net.bridge.bridge-nf-call-ip6tables = 1` | Same as above for IPv6 traffic — required even on IPv4-only clusters because some CNI plugins use IPv6 internally. |
| `net.ipv4.ip_forward = 1` | Allows the kernel to forward packets between network interfaces. Without this, pods on different nodes cannot route to each other. |

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### ✅ Verify 2.4
```bash
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward
# Expected:
# net.bridge.bridge-nf-call-iptables = 1
# net.ipv4.ip_forward = 1
```

---

### STEP 2.5 — Install and Configure containerd

containerd is the **container runtime** — it pulls images and runs containers. Kubernetes uses it via the CRI (Container Runtime Interface).

**Add Docker’s apt repository and install `containerd.io`:**

> `containerd.io` is Docker’s distribution of containerd. It is more up-to-date than the `containerd` package in Ubuntu’s default repos and is the version used in production clusters.

```bash
# Add Docker's GPG key
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

**Generate the default config:**
```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
```

**Enable systemd cgroup driver** (required by kubeadm):
```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

**Restart and enable:**
```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### ✅ Verify 2.5
```bash
sudo systemctl is-active containerd
# Expected: active

grep SystemdCgroup /etc/containerd/config.toml
# Expected: SystemdCgroup = true
```

---

### STEP 2.6 — Install kubeadm, kubelet, and kubectl

These are the three Kubernetes binaries every node needs:

| Binary | Purpose |
|---|---|
| `kubeadm` | Bootstraps and joins the cluster |
| `kubelet` | The node agent — runs and monitors pods |
| `kubectl` | The CLI for interacting with the cluster (useful for debugging from workers) |

```bash
# Add the Kubernetes apt repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Enable kubelet so it starts automatically when kubeadm join runs
sudo systemctl enable kubelet
```

`apt-mark hold` prevents accidental upgrades that could break cluster compatibility.

### ✅ Verify 2.6
```bash
kubeadm version
kubelet --version
kubectl version --client
# All three should show: v1.29.x
```

---

### STEP 2.7 — Pre-flight Check

Confirm all components are ready before joining:

```bash
echo "--- containerd ---"
sudo systemctl is-active containerd

echo "--- swap ---"
free -h | grep Swap

echo "--- kernel modules ---"
lsmod | grep -E "overlay|br_netfilter"

echo "--- kubeadm ---"
kubeadm version

echo "--- kubelet ---"
sudo systemctl is-enabled kubelet
```

**Expected output:**
```
--- containerd ---
active
--- swap ---
Swap:          0B         0B         0B
--- kernel modules ---
br_netfilter          xxxxx  0
overlay               xxxxx  0
--- kubeadm ---
kubeadm version: &version.Info{GitVersion:"v1.29.x", ...}
--- kubelet ---
enabled
```

> `kubelet` shows `enabled` but may report `inactive` — that is normal. It starts automatically when `kubeadm join` runs.

---

## STEP 3 — Get the Join Command from the Master

You need the `kubeadm join` command that was generated on the master node. It looks like:

```
kubeadm join 10.0.1.12:6443 --token abcdef.1234567890abcdef \
        --discovery-token-ca-cert-hash sha256:abc123def456...
```

**From the master node, run one of these:**

```bash
# Option A: Read from the saved init log
tail -5 /tmp/kubeadm-init.log

# Option B: Generate a fresh join command (tokens expire after 24h)
sudo kubeadm token create --print-join-command
```

You need three values from this output:

| Value | Where in the join command |
|---|---|
| `MASTER_IP` | The IP before `:6443` — e.g., `10.0.1.12` |
| `JOIN_TOKEN` | After `--token` — e.g., `abcdef.1234567890abcdef` |
| `JOIN_HASH` | After `--discovery-token-ca-cert-hash sha256:` — the long hex string |

> Always use the master's **private IP** (10.x.x.x), not the public IP.

---

## STEP 4 — Join the Cluster

### 4.1 Verify connectivity to the master (pre-check)

Before running `kubeadm join`, confirm the worker can reach the master’s API server on port 6443. This is the port `kubeadm join` connects to.

```bash
nc -zw5 <MASTER_IP> 6443
# Expected: (exits with code 0, no error)
```

If this fails, the join will also fail. Fix the security group inbound rule on the master’s SG: add TCP port 6443 from the worker’s subnet CIDR.

### 4.2 Check if this node was previously joined

If `/etc/kubernetes/kubelet.conf` already exists, this node has already joined a cluster. Running `kubeadm join` again will fail.

```bash
ls /etc/kubernetes/kubelet.conf
# If this file exists, reset first:
sudo kubeadm reset -f
```

Only run the reset if you intend to re-join (e.g. joining a different cluster or recovering from a failed attempt).

### 4.3 Run the join

**Option A — Use the script (recommended)**

```bash
cd ~/kubernetes-fundamentals/labs/lab-01-kubeadm
sudo ./worker-join.sh
```

The script will prompt for the three values interactively:
```
  Master Private IP   (e.g. 10.0.1.12)             : 10.0.1.12
  Join Token          (e.g. abcdef.1234567890abcdef): abcdef.1234567890abcdef
  Discovery CA Hash   (e.g. sha256:abc123...)       : sha256:abc123...
```

Alternatively, pass values as environment variables (non-interactive, useful for automation):
```bash
sudo MASTER_IP=10.0.1.12 \
     JOIN_TOKEN=abcdef.1234567890abcdef \
     JOIN_HASH=sha256:abc123def456... \
     ./worker-join.sh
```

**Option B — Manual `kubeadm join`**

```bash
sudo kubeadm join <MASTER_IP>:6443 \
  --token <JOIN_TOKEN> \
  --discovery-token-ca-cert-hash sha256:<JOIN_HASH>
```

Replace `<MASTER_IP>`, `<JOIN_TOKEN>`, and `<JOIN_HASH>` with your actual values.

**Expected output** (after 30–60 seconds):
```
[preflight] Running pre-flight checks
[preflight] Reading configuration from the cluster...
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Starting the kubelet
...
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.

Run 'kubectl get nodes' on the control-plane to see this node join the cluster.
```

### ✅ Verify on the worker node itself

```bash
sudo systemctl is-active kubelet
# Expected: active
```

---

## STEP 5 — Verify from the Master Node

**Switch back to your master terminal** and run:

```bash
kubectl get nodes -w
```

Watch live updates. Within 60–90 seconds, the worker should transition from `NotReady` to `Ready`:

```
NAME           STATUS     ROLES           AGE   VERSION
k8s-master     Ready      control-plane   15m   v1.29.0
k8s-worker-1   NotReady   <none>          10s   v1.29.0
k8s-worker-1   Ready      <none>          45s   v1.29.0
```

Press `Ctrl+C` once the worker shows `Ready`.

Also confirm the worker is visible in detail:
```bash
kubectl get nodes -o wide
```

Expected:
```
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE
k8s-master     Ready    control-plane   15m   v1.29.0   10.0.1.x      Ubuntu 22.04
k8s-worker-1   Ready    <none>          2m    v1.29.0   10.0.1.x      Ubuntu 22.04
```

---

## STEP 6 — Repeat on k8s-worker-2

Repeat **STEP 0 through STEP 5** on the second worker node. The process is identical.

SSH into k8s-worker-2:
```bash
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<WORKER_2_PUBLIC_IP>
```

Then run:
```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm
sudo ./worker-join.sh
```

Use the **same** join command/token — or regenerate on the master if it expired.

---

## STEP 7 — Final Cluster Verification (from Master)

Once both workers have joined, run a full health check from the master node:

### 7.1 All three nodes Ready
```bash
kubectl get nodes -o wide
```

Expected:
```
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP
k8s-master     Ready    control-plane   20m   v1.29.0   10.0.1.x
k8s-worker-1   Ready    <none>          5m    v1.29.0   10.0.1.x
k8s-worker-2   Ready    <none>          2m    v1.29.0   10.0.1.x
```

### 7.2 All system pods running
```bash
kubectl get pods -n kube-system -o wide
```

All pods should show `Running`. Two `calico-node` and two `kube-proxy` pods should now exist (one per worker).

### 7.3 Deploy a test pod and verify scheduling on workers

```bash
kubectl run test-nginx --image=nginx:alpine
sleep 10
kubectl get pods -o wide
```

Expected: Pod running on one of the workers (not the master — tainted by default):
```
NAME         READY   STATUS    NODE
test-nginx   1/1     Running   k8s-worker-1
```

Test the pod is reachable:
```bash
kubectl exec test-nginx -- curl -s http://localhost
# Expected: nginx welcome HTML
```

Clean up:
```bash
kubectl delete pod test-nginx
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `nc -zw5 <master-ip> 6443` fails | Security group missing port 6443 | AWS Console → Security Group → add inbound TCP 6443 from worker subnet |
| `error: could not find a JWS signature` | Token expired | `sudo kubeadm token create --print-join-command` on master |
| `x509: certificate has expired` | Clock mismatch between nodes | `sudo timedatectl set-ntp true` on the worker, retry |
| Worker shows `NotReady` after 3 min | Calico not reaching worker | `kubectl describe node k8s-worker-1` → check Events section |
| `kubelet` not starting on worker | Swap still enabled | `sudo swapoff -a` then `sudo systemctl restart kubelet` |
| Join succeeds but node never appears | Wrong MASTER_IP used | Verify you used the **private** IP (10.x.x.x), not the public IP |
| `WARN: InitConfiguration found but will not use it` | Old kubelet state | `sudo kubeadm reset -f` on the worker, then re-run join |
| Container runtime not found | containerd not active | `sudo systemctl restart containerd` then retry join |

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
