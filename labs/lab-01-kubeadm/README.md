# lab-01-kubeadm — Self-Hosted Kubernetes Cluster on EC2

Bootstrap a fully functional, multi-node Kubernetes cluster on AWS EC2 from scratch using **kubeadm**. No managed control plane, no abstraction layers — every component is installed, configured, and owned by you.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Technology Stack](#2-technology-stack)
3. [Directory Layout](#3-directory-layout)
4. [Prerequisites](#4-prerequisites)
5. [Step 1 — Provision EC2 Instances](#5-step-1--provision-ec2-instances)
6. [Step 2 — Bootstrap the Master Node](#6-step-2--bootstrap-the-master-node)
7. [Step 3 — Join Worker Nodes](#7-step-3--join-worker-nodes)
8. [Step 4 — Verify the Cluster](#8-step-4--verify-the-cluster)
9. [Operational Reference](#9-operational-reference)
10. [Making Changes Safely](#10-making-changes-safely)
11. [Teardown](#11-teardown)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture Overview

```
AWS ap-south-1 (devops-vpc  10.0.0.0/16)
│
├── Public Subnet  10.0.0.0/20  (ap-south-1a)
│   └── node-public-1   ← Kubernetes MASTER
│         • kube-apiserver  :6443
│         • etcd            :2379-2380
│         • kube-scheduler
│         • kube-controller-manager
│         • Calico CNI
│
└── Private Subnet 10.0.128.0/20  (ap-south-1a)
    ├── node-private-1  ← Kubernetes WORKER
    └── node-private-2  ← Kubernetes WORKER
          • kubelet
          • kube-proxy
          • containerd (container runtime)
          • Calico CNI agent
```

**Pod network:** `192.168.0.0/16` — Calico assigns individual pod IPs from this range. Non-overlapping with VPC CIDR, so AWS routing is unaffected.

**Design decisions:**

| Decision | Rationale |
|---|---|
| kubeadm over managed EKS | Full visibility into every component; mirrors production on-prem setup |
| containerd (not Docker) | Docker shim was removed in Kubernetes 1.24+; containerd is the standard CRI |
| Calico CNI | Production-grade, supports NetworkPolicy enforcement, widely used |
| Kubernetes 1.29 | LTS-equivalent; stable API, broad community support |
| `apt-mark hold` on k8s packages | Prevents accidental version drift during routine `apt upgrade` |
| systemd cgroup driver | Required to match what kubelet expects; avoids node pressure instability |
| Idempotent scripts | Every step checks current state before acting — safe to re-run after partial failures |

---

## 2. Technology Stack

| Layer | Technology | Version |
|---|---|---|
| Cloud | AWS EC2 | — |
| OS | Ubuntu | 22.04 LTS |
| Container Runtime | containerd (Docker repo `containerd.io`) | latest stable |
| Cluster Bootstrapper | kubeadm | 1.29.0 |
| Node Agent | kubelet | 1.29.0 |
| CLI | kubectl | 1.29.0 |
| CNI Plugin | Calico | v3.27.0 |
| Provisioning | AWS CLI v2 + Bash | — |
| Instance type | t3.medium (2 vCPU / 4 GB RAM) | — |
| Region | ap-south-1 (Mumbai) | — |

> **Why `containerd.io` from the Docker apt repo, not `containerd` from Ubuntu repos?**
> The Ubuntu-packaged `containerd` lags behind in version and is missing the `containerd.io` config tooling. The Docker repo version is the reference implementation used by the Kubernetes project.

---

## 3. Directory Layout

```
labs/lab-01-kubeadm/
├── provision-ec2.sh       # Launch/teardown EC2 instances (run from your laptop)
├── master-init.sh         # Full master node bootstrap (run ON the master EC2)
├── master-init-guide.md   # Manual step-by-step equivalent of master-init.sh
├── worker-join.sh         # Full worker node bootstrap (run ON each worker EC2)
└── worker-join-guide.md   # Manual step-by-step equivalent of worker-join.sh
```

The `.sh` scripts are self-contained and authoritative. The `*-guide.md` files mirror each script step-by-step for learning or manual execution.

---

## 4. Prerequisites

### On your local machine (laptop / workstation)

| Tool | Minimum version | Install |
|---|---|---|
| AWS CLI v2 | 2.x | [docs.aws.amazon.com](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| AWS profile configured | — | `aws configure --profile sarowar-ostad` |
| EC2 Key Pair | — | Must exist in `ap-south-1`, named `sarowar-ostad-mumbai` |
| SSH client | — | Built-in on Linux/macOS; Git Bash or PuTTY on Windows |
| Bash | 4.x+ | Built-in on Linux/macOS; Git Bash on Windows |

Verify AWS access:
```bash
aws sts get-caller-identity --profile sarowar-ostad
```

### On each EC2 instance (master and workers)

The scripts install everything from scratch. The only requirement is:

- **Ubuntu 22.04 LTS** (AMI `ami-05d2d839d4f73aafb` in ap-south-1)
- **2+ vCPU, 4+ GB RAM** (t3.medium satisfies this)
- **Internet access** (to pull apt packages and container images)
- Script must be run as **root** (`sudo`)

---

## 5. Step 1 — Provision EC2 Instances

`provision-ec2.sh` launches the master (public subnet) and worker (private subnet) EC2 instances, waits for them to reach `running` state, and writes all instance IDs and IPs to `cluster-state.env`.

### Configure

Open `provision-ec2.sh` and verify the top section or override via environment variables:

```
AWS_PROFILE  = sarowar-ostad
AWS_REGION   = ap-south-1
AMI_ID       = ami-05d2d839d4f73aafb   (Ubuntu 22.04 LTS, ap-south-1)
VPC_ID       = vpc-06f7dead5c49ece64   (devops-vpc)
PUBLIC_SUBNET_ID  = subnet-0880772cfbeb8bb6f  (ap-south-1a public)
PRIVATE_SUBNET_ID = subnet-054147291dc0bf764  (ap-south-1a private)
SECURITY_GROUP_ID = sg-097d6afb08616ba09      (devops-vpc default SG)
INSTANCE_TYPE     = t3.medium
KEY_NAME          = sarowar-ostad-mumbai
INSTANCE_PROFILE_NAME = SSM
PUBLIC_COUNT   = 1   (master node count)
PRIVATE_COUNT  = 2   (worker node count)
```

### Run

```bash
cd labs/lab-01-kubeadm
bash provision-ec2.sh
```

After completion, inspect the output file:
```bash
cat cluster-state.env
```

Example output:
```
PUBLIC_1_INSTANCE_ID=i-0abc123...
PUBLIC_1_PUBLIC_IP=13.233.x.x
PUBLIC_1_PRIVATE_IP=10.0.0.45
PRIVATE_1_INSTANCE_ID=i-0def456...
PRIVATE_1_PRIVATE_IP=10.0.128.12
PRIVATE_2_INSTANCE_ID=i-0ghi789...
PRIVATE_2_PRIVATE_IP=10.0.128.34
```

> The `SSM` IAM instance profile is attached to all instances, enabling **AWS Systems Manager Session Manager** access — an alternative to SSH that requires no open inbound ports.

---

## 6. Step 2 — Bootstrap the Master Node

SSH into the **public** instance (the master):

```bash
source cluster-state.env
ssh -i ~/.ssh/sarowar-ostad-mumbai.pem ubuntu@${PUBLIC_1_PUBLIC_IP}
```

#### Option A — Automated (recommended)

```bash
sudo apt-get install -y git
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm
chmod +x master-init.sh
sudo ./master-init.sh
```

#### Option B — One-liner (no git required)

```bash
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/kubernetes-fundamentals/main/labs/lab-01-kubeadm/master-init.sh | sudo bash
```

### What the script does

| Step | Action |
|---|---|
| 1/7 | apt update + upgrade; installs `curl`, `gnupg`, `wget`, `git`, `ca-certificates` |
| 2/7 | Disables swap (`swapoff -a`) and comments it out in `/etc/fstab` (persistent) |
| 3/7 | Loads `overlay` and `br_netfilter` kernel modules; persists via `/etc/modules-load.d/k8s.conf` |
| 4/7 | Writes `/etc/sysctl.d/k8s.conf` — enables bridge iptables and IP forwarding |
| 5/7 | Adds Docker apt repo; installs `containerd.io`; configures systemd cgroup driver |
| 6/7 | Adds Kubernetes apt repo; installs `kubelet`, `kubeadm`, `kubectl`; pins versions with `apt-mark hold` |
| 7/7 | Pre-flight: asserts swap=OFF, containerd active, tools installed |
| 8/11 | `kubeadm init` with pod CIDR `192.168.0.0/16` and master private IP as advertise address |
| 9/11 | Copies `admin.conf` to `~ubuntu/.kube/config` — kubectl works as the `ubuntu` user |
| 10/11 | Applies Calico CNI manifests from the official Calico release |
| 11/11 | Generates worker join command; saves to `/tmp/worker-join-command.txt` |

### After the script completes

The terminal will print the worker join command. **Copy it.** It looks like:

```
sudo kubeadm join 10.0.0.45:6443 \
  --token abcdef.1234567890abcdef \
  --discovery-token-ca-cert-hash sha256:abc123...
```

It is also saved on the master at `/tmp/worker-join-command.txt`. Retrieve it any time:
```bash
cat /tmp/worker-join-command.txt
```

Regenerate a new token at any time (old ones expire in 24 h):
```bash
sudo kubeadm token create --print-join-command
```

---

## 7. Step 3 — Join Worker Nodes

Repeat for each worker. SSH into a private instance via the master as a jump host:

```bash
source cluster-state.env
ssh -J ubuntu@${PUBLIC_1_PUBLIC_IP} \
    -i ~/.ssh/sarowar-ostad-mumbai.pem \
    ubuntu@${PRIVATE_1_PRIVATE_IP}
```

#### Option A — Interactive (prompts for join values)

```bash
sudo apt-get install -y git
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm
chmod +x worker-join.sh
sudo ./worker-join.sh
# Enter: Master Private IP, Token, and CA Hash when prompted
```

#### Option B — Non-interactive (pass values as env vars)

```bash
sudo MASTER_IP=10.0.0.45 \
     JOIN_TOKEN=abcdef.1234567890abcdef \
     JOIN_HASH=sha256:abc123... \
     ./worker-join.sh
```

#### Option C — One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/kubernetes-fundamentals/main/labs/lab-01-kubeadm/worker-join.sh \
  | sudo MASTER_IP=10.0.0.45 JOIN_TOKEN=abc.def JOIN_HASH=sha256:xxx bash
```

### What the script does

Steps 1–7 are identical to `master-init.sh` Phase 1 (system prep). Phase 2 additionally:

- Checks TCP connectivity to `MASTER_IP:6443` using `nc` before joining — fails fast with a clear error if the security group blocks port 6443
- Checks for `/etc/kubernetes/kubelet.conf` to detect an already-joined node and exits gracefully instead of running `kubeadm join` twice
- Runs `kubeadm join` with the provided token and CA hash

---

## 8. Step 4 — Verify the Cluster

Run these from the **master node** as the `ubuntu` user:

```bash
# All nodes should reach Ready status within ~60 seconds of the last worker joining
kubectl get nodes

# Expected output (after Calico initialises):
# NAME            STATUS   ROLES           AGE   VERSION
# ip-10-0-0-45    Ready    control-plane   5m    v1.29.0
# ip-10-0-128-12  Ready    <none>          2m    v1.29.0
# ip-10-0-128-34  Ready    <none>          1m    v1.29.0

# All system pods should be Running or Completed
kubectl get pods -n kube-system

# Watch node status in real time
kubectl get nodes -w
```

If nodes are `NotReady`, check Calico:
```bash
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl describe pod <calico-pod-name> -n kube-system
```

---

## 9. Operational Reference

### Copy kubeconfig to your laptop (run locally)

```bash
source cluster-state.env
scp -i ~/.ssh/sarowar-ostad-mumbai.pem \
    ubuntu@${PUBLIC_1_PUBLIC_IP}:~/.kube/config \
    ~/.kube/config-k8s-demo
export KUBECONFIG=~/.kube/config-k8s-demo
kubectl get nodes
```

### Deploy a test workload

```bash
kubectl create deployment nginx --image=nginx --replicas=2
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get svc nginx
```

### Cluster Autoscaler / scaling

This lab does not include the Cluster Autoscaler. Scale node groups manually:

```bash
# Add a worker: provision a new EC2 and run worker-join.sh
# Remove a worker:
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>
# Then terminate the EC2 instance
```

### Token management

Kubeadm bootstrap tokens expire after **24 hours**. If a worker needs to join after that:

```bash
# On the master:
sudo kubeadm token create --print-join-command
```

### Key file locations on each node

| Path | Purpose |
|---|---|
| `/etc/kubernetes/admin.conf` | Cluster admin kubeconfig (root only) |
| `~ubuntu/.kube/config` | Per-user kubeconfig (ubuntu user) |
| `/etc/kubernetes/manifests/` | Static pod manifests for control plane components |
| `/etc/containerd/config.toml` | containerd configuration (systemd cgroup driver) |
| `/etc/sysctl.d/k8s.conf` | Persistent kernel networking parameters |
| `/etc/modules-load.d/k8s.conf` | Kernel modules loaded at boot |
| `/tmp/worker-join-command.txt` | Generated join command (master only) |
| `/tmp/kubeadm-init.log` | Full kubeadm init output (master only) |

---

## 10. Making Changes Safely

### Upgrading Kubernetes version

The packages are pinned with `apt-mark hold`. To upgrade:

```bash
# Unpin, upgrade, re-pin — on master first, then each worker
sudo apt-mark unhold kubelet kubeadm kubectl
sudo apt-get update && sudo apt-get install -y kubelet=<new-version> kubeadm=<new-version> kubectl=<new-version>
sudo apt-mark hold kubelet kubeadm kubectl
sudo kubeadm upgrade apply v<new-version>    # master only
sudo kubeadm upgrade node                    # workers
sudo systemctl restart kubelet
```

Follow the Kubernetes [version skew policy](https://kubernetes.io/releases/version-skew-policy/): upgrade one minor version at a time. Never skip versions.

### Replacing containerd config

If you change `/etc/containerd/config.toml`:
```bash
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

Verify containerd is running before restarting kubelet:
```bash
sudo systemctl status containerd
```

### Drain before node maintenance

Always drain a node before OS updates or reboots:
```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
# Perform maintenance...
kubectl uncordon <node-name>
```

### Re-running scripts after partial failure

All scripts are **idempotent** — every step checks current state before acting. Re-running after a failure is safe and will resume from where it stopped (kubeadm init is the only exception; if it partially ran, do `sudo kubeadm reset -f` first).

---

## 11. Teardown

### Automated teardown (removes all EC2 instances)

```bash
cd labs/lab-01-kubeadm
bash provision-ec2.sh --teardown
```

This reads `cluster-state.env`, shows a list of instances, asks for confirmation, then terminates all of them and deletes the state file.

### Kubernetes-level cleanup (before decommissioning nodes)

```bash
# From master — drain and delete each worker
kubectl drain <worker-node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <worker-node>

# Reset master
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d ~/.kube
```

> **Cost reminder:** EC2 charges accrue by the hour. Always verify instances are terminated in the AWS Console after teardown.

---

## 12. Troubleshooting

### Node stays `NotReady`

```bash
# Check kubelet logs on the affected node
sudo journalctl -xeu kubelet --no-pager | tail -50

# Check Calico pods
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
```

Common causes:
- Calico pods `CrashLoopBackOff` — re-apply: `kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml`
- `PLEG is not healthy` in kubelet logs — containerd issue; run `sudo systemctl restart containerd kubelet`

### Worker cannot reach master (`nc` fails)

```bash
nc -zw5 <MASTER_PRIVATE_IP> 6443
```

Causes:
- AWS Security Group on the master does not allow inbound TCP 6443 from the worker's subnet — add an inbound rule
- Master kubelet/apiserver not running — check `sudo systemctl status kube-apiserver` (or check `/etc/kubernetes/manifests/`)

### `kubeadm init` fails with `port in use`

The control plane was partially initialised. Reset and retry:
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo ./master-init.sh
```

### Swap still active after reboot

```bash
sudo swapoff -a
grep -E '\bswap\b' /etc/fstab   # should show only commented lines
```

If an uncommented swap line is present, comment it out manually:
```bash
sudo sed -i '/\bswap\b/s/^/#/' /etc/fstab
```

### `kubectl` returns `connection refused` on master

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl cluster-info
```

If the apiserver is not running, inspect static pod manifests:
```bash
sudo ls /etc/kubernetes/manifests/
sudo crictl ps -a   # list all containers including failed ones
```

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
