# Lab 1 — Kubernetes Cluster with kubeadm on AWS (Mumbai)

**Duration:** ~90 minutes  
**Level:** Beginner  
**Region:** ap-south-1 (Mumbai)

---

## What You Will Build

```
AWS ap-south-1 (Mumbai)
│
└── VPC: 10.0.0.0/16
    └── Public Subnet: 10.0.1.0/24
        ├── k8s-master   (t3.medium) ← control plane runs here
        ├── k8s-worker-1 (t3.medium) ← your apps run here
        └── k8s-worker-2 (t3.medium) ← your apps run here
```

At the end of this lab you will have:
- A fully functional Kubernetes 1.29 cluster
- Calico CNI for pod networking
- `kubectl` configured to manage the cluster
- A running nginx pod to verify everything works

---

## Prerequisites

- AWS CLI v2 installed, profile `sop` configured
- SSH key pair named `k8s-lab-key` exists in ap-south-1
- Cluster already provisioned via `scripts/provision-cluster.sh`

---

## Phase 1 — Prepare All Nodes  
*Run on: Master + both Workers*

### 1.1 Copy the preparation script to each node

On your local machine, run:

```bash
# Load IPs from the state file
source scripts/cluster-state.env

# Copy the prep script to all 3 nodes
scp -i ~/.ssh/k8s-lab-key.pem \
  scripts/install-kubeadm-node.sh \
  ubuntu@${MASTER_IP}:~/

scp -i ~/.ssh/k8s-lab-key.pem \
  scripts/install-kubeadm-node.sh \
  ubuntu@${WORKER1_IP}:~/

scp -i ~/.ssh/k8s-lab-key.pem \
  scripts/install-kubeadm-node.sh \
  ubuntu@${WORKER2_IP}:~/
```

### 1.2 SSH into each node and run the script

**Open 3 terminals** (or use tmux). In each terminal, SSH into one node:

```bash
# Terminal 1 — Master
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<MASTER_IP>
sudo ./install-kubeadm-node.sh

# Terminal 2 — Worker 1
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<WORKER1_IP>
sudo ./install-kubeadm-node.sh

# Terminal 3 — Worker 2
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<WORKER2_IP>
sudo ./install-kubeadm-node.sh
```

**Expected output** (on each node):
```
[OK] System updated.
[OK] Swap disabled.
[OK] Kernel modules loaded.
[OK] Kernel networking parameters configured.
[OK] containerd installed and configured.
[OK] kubeadm, kubelet, kubectl installed and pinned.
NODE PREPARATION COMPLETE
```

**Wait until all 3 nodes show "NODE PREPARATION COMPLETE" before proceeding.**

---

## Phase 2 — Initialize the Master Node  
*Run on: Master node only*

### 2.1 Copy and run the master init script

```bash
# On master node only
sudo ./master-init.sh
```

Or run the commands manually (explained below).

### 2.2 Manual step-by-step (what master-init.sh does)

#### 2.2.1 Initialize the cluster with kubeadm

```bash
# Get the private IP of this master node
MASTER_PRIVATE_IP=$(hostname -I | awk '{print $1}')

# Initialize the Kubernetes control plane
sudo kubeadm init \
  --apiserver-advertise-address=${MASTER_PRIVATE_IP} \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=1.29.0 \
  --ignore-preflight-errors=NumCPU
```

**What each flag means:**
- `--apiserver-advertise-address` — The IP that other nodes will use to reach the API server. Use the **private** IP (internal network).
- `--pod-network-cidr=192.168.0.0/16` — The IP range for pods. We use `192.168.0.0/16` because Calico expects this range.
- `--kubernetes-version=1.29.0` — Pin the version (avoids using a newer version than our tools expect).
- `--ignore-preflight-errors=NumCPU` — t3.medium has 2 vCPU; kubeadm warns about this. Flag suppresses the warning.

**This takes 2-3 minutes.** You'll see output like:
```
[init] Using Kubernetes version: v1.29.0
[preflight] Running pre-flight checks
[certs] Generating certificates...
[kubeconfig] Writing kubeconfig files...
[control-plane] Creating static Pod manifests...
...
Your Kubernetes control-plane has initialized successfully!
```

At the very end, you will see a `kubeadm join` command. **Copy this — you need it for the workers.**

Example:
```
kubeadm join 10.0.1.x:6443 --token abcdef.1234567890abcdef \
  --discovery-token-ca-cert-hash sha256:abc123...
```

#### 2.2.2 Configure kubectl on the master node

```bash
# Run these 3 commands EXACTLY as printed by kubeadm init
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**WHY:** kubectl reads connection info from `~/.kube/config`. Without this step, every `kubectl` command fails with "refused connection".

**Verify kubectl works:**
```bash
kubectl get nodes
```

Expected output:
```
NAME         STATUS     ROLES           AGE   VERSION
k8s-master   NotReady   control-plane   1m    v1.29.0
```

`NotReady` is normal here — we haven't installed the network plugin yet.

#### 2.2.3 Install Calico CNI (Container Network Interface)

```bash
# Download and apply the Calico manifest
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

**WHY Calico?**
- Pods need a network to talk to each other. Without a CNI plugin, pods can't communicate.
- Calico is the most production-ready open-source option.
- It also supports Network Policies (firewall rules between pods) for future modules.

**Wait for Calico pods to become ready:**
```bash
watch kubectl get pods -n kube-system
```

Wait until all `calico-*` pods show `Running`. Press Ctrl+C when done.

**Re-check nodes:**
```bash
kubectl get nodes
```

Expected output (master should now be `Ready`):
```
NAME         STATUS   ROLES           AGE   VERSION
k8s-master   Ready    control-plane   5m    v1.29.0
```

---

## Phase 3 — Join Worker Nodes  
*Run on: Worker nodes only*

### 3.1 Use the join command from kubeadm init output

SSH into **Worker Node 1**:

```bash
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<WORKER1_IP>
```

Run the join command (substitute your actual token and hash):

```bash
sudo kubeadm join <MASTER_PRIVATE_IP>:6443 \
  --token <your-token> \
  --discovery-token-ca-cert-hash sha256:<your-hash>
```

Repeat on **Worker Node 2**.

**Expected output on each worker:**
```
[preflight] Running pre-flight checks
[kubelet-start] Activating the kubelet service
...
This node has joined the cluster:
* Certificate signing request was sent to apiserver.
* The Kubelet was informed of the new secure connection details.
```

> **Token expired?** If you're joining more than 24 hours later, generate a new token on the master:
> ```bash
> kubeadm token create --print-join-command
> ```

### 3.2 Verify the cluster from the master node

```bash
# Back on the master node
kubectl get nodes
```

Expected output (all nodes Ready):
```
NAME           STATUS   ROLES           AGE   VERSION
k8s-master     Ready    control-plane   10m   v1.29.0
k8s-worker-1   Ready    <none>          2m    v1.29.0
k8s-worker-2   Ready    <none>          1m    v1.29.0
```

**Congratulations — your cluster is up!**

---

## Phase 4 — Verify Cluster Health

Run these checks on the master node:

```bash
# 1. Check all nodes
kubectl get nodes -o wide

# 2. Check all system pods
kubectl get pods -n kube-system

# 3. Check control plane component health
kubectl get componentstatuses

# 4. Check cluster info
kubectl cluster-info

# 5. Check API server is responding
kubectl get namespaces
```

**Expected namespaces:**
```
NAME              STATUS   AGE
default           Active   15m
kube-node-lease   Active   15m
kube-public       Active   15m
kube-system       Active   15m
```

---

## Phase 5 — Deploy Your First Application

```bash
# Create an nginx deployment (3 replicas)
kubectl create deployment nginx-demo \
  --image=nginx:alpine \
  --replicas=3

# Check pods are distributed across workers
kubectl get pods -o wide

# Expose the deployment as a NodePort service
kubectl expose deployment nginx-demo \
  --port=80 \
  --type=NodePort

# Find the NodePort assigned
kubectl get service nginx-demo
```

Expected output:
```
NAME         TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
nginx-demo   NodePort   10.96.x.x       <none>        80:3xxxx/TCP   1m
```

**Access the app** in your browser (using any worker node's public IP):
```
http://<WORKER1_IP>:<NodePort>
```

You should see the nginx welcome page.

---

## Phase 6 — Self-Healing Demo

This demonstrates one of Kubernetes' most important features.

```bash
# Watch pods in real time (keep this running)
watch kubectl get pods -o wide

# In a NEW terminal on master node, delete one pod
kubectl delete pod <one-of-the-nginx-pods>
```

**Observe:** The deleted pod disappears. Within seconds, a NEW pod with a different name appears.

**Why?** The Deployment told Kubernetes: "I always want 3 replicas." The Controller Manager checked — only 2 running. It immediately created a new one.

This is **self-healing** in action.

---

## Phase 7 — Cleanup (Optional)

```bash
# Delete the demo deployment and service
kubectl delete deployment nginx-demo
kubectl delete service nginx-demo

# Tear down AWS resources (run from your local machine)
./scripts/teardown-cluster.sh
```

---

## Troubleshooting

| Problem | Command to Diagnose | Fix |
|---|---|---|
| Node stays `NotReady` | `kubectl describe node <name>` | Check if Calico pods are running: `kubectl get pods -n kube-system` |
| Pod stuck in `Pending` | `kubectl describe pod <name>` | Read the "Events" section — usually resource or scheduling error |
| `kubectl` not connecting | `echo $KUBECONFIG` or `cat ~/.kube/config` | Re-run the 3 copy commands from kubeadm init |
| kubeadm join fails | Check token: `kubeadm token list` | Regenerate: `kubeadm token create --print-join-command` |
| containerd not running | `systemctl status containerd` | `sudo systemctl restart containerd` |
