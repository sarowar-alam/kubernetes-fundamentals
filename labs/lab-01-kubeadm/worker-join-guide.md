# Worker Node Join — Manual Execution Guide

**Companion to:** `worker-join.sh`  
**Run on:** Each Worker Node (k8s-worker-1 AND k8s-worker-2)  
**Pre-requisite:** `master-init-guide.md` must be fully complete and the master node must be `Ready`

---

## Overview

This guide walks you through every step to join a worker node to the Kubernetes cluster.

```
STEP 1 → Verify pre-conditions         (node ready, master reachable)
STEP 2 → Get the join command          (from master node output)
STEP 3 → Run kubeadm join             (connect this node to the cluster)
STEP 4 → Verify from master            (confirm node appears as Ready)
STEP 5 → Repeat on second worker       (k8s-worker-2)
```

---

## Before You Start

You need three values from the master node's `kubeadm init` output:

| Value | Example | Where to find it |
|---|---|---|
| `MASTER_IP` | `10.0.1.12` | Private IP of master (from `cluster-state.env` or AWS Console) |
| `JOIN_TOKEN` | `abcdef.1234567890abcdef` | `kubeadm init` output or regenerate on master |
| `JOIN_HASH` | `sha256:abc123...` | `kubeadm init` output or regenerate on master |

### Retrieve the join command from the master node

SSH into the master node and run:
```bash
sudo kubeadm token create --print-join-command
```

**Example output:**
```
kubeadm join 10.0.1.12:6443 --token abcdef.1234567890abcdef \
        --discovery-token-ca-cert-hash sha256:abc123def456...
```

Keep this output visible — you will paste it on the worker nodes.

---

## STEP 1 — Pre-condition Checks (on the worker node)

SSH into **Worker Node 1**:
```bash
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<WORKER1_PUBLIC_IP>
```

### 1.1 Confirm you are on the correct machine
```bash
hostname
# Expected: k8s-worker-1
```

### 1.2 Confirm kubeadm is installed
```bash
kubeadm version
# Expected: kubeadm version: &version.Info{GitVersion:"v1.29.x", ...}
```

### 1.3 Confirm swap is disabled
```bash
free -h | grep Swap
# Expected:
# Swap:          0B         0B         0B
```

### 1.4 Confirm containerd is running
```bash
sudo systemctl status containerd | grep Active
# Expected: Active: active (running)
```

### 1.5 Confirm the worker can reach the master API server
```bash
# Replace 10.0.1.12 with your actual master private IP
nc -zv 10.0.1.12 6443
# Expected: Connection to 10.0.1.12 6443 port [tcp/*] succeeded!
```

> If this fails, check the AWS security group — port 6443 must be open between nodes.

---

## STEP 2 — Run kubeadm join

On the worker node, run the full join command you copied from the master.

### Option A — Paste the command directly
```bash
sudo kubeadm join 10.0.1.12:6443 \
  --token abcdef.1234567890abcdef \
  --discovery-token-ca-cert-hash sha256:abc123def456...
```

> Replace `10.0.1.12`, the token, and the hash with your actual values.

### Option B — Export as variables, then run
```bash
export MASTER_IP=10.0.1.12
export JOIN_TOKEN=abcdef.1234567890abcdef
export JOIN_HASH=sha256:abc123def456...

sudo kubeadm join "${MASTER_IP}:6443" \
  --token "${JOIN_TOKEN}" \
  --discovery-token-ca-cert-hash "${JOIN_HASH}"
```

**Expected output:**
```
[preflight] Running pre-flight checks
[preflight] Reading configuration from the cluster...
[preflight] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -o yaml'
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
[kubelet-start] Activating the kubelet service
[kubelet-start] Waiting for the kubelet to perform the TLS Bootstrap...

This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.

Run 'kubectl get nodes' on the control-plane to see this node join the cluster.
```

---

## STEP 3 — Verify from the Master Node

Switch to your **master node** terminal and check:

### 3.1 The worker appears in the node list
```bash
kubectl get nodes
```

Run this immediately after the join — the worker may show `NotReady` for up to 60 seconds while kubelet starts and Calico configures networking. Keep watching:

```bash
kubectl get nodes -w
```

**Expected final state:**
```
NAME           STATUS   ROLES           AGE   VERSION
k8s-master     Ready    control-plane   10m   v1.29.0
k8s-worker-1   Ready    <none>          45s   v1.29.0
```

Press `Ctrl+C` once the worker shows `Ready`.

### 3.2 Confirm the worker's kubelet is healthy
Back on the **worker node**:
```bash
sudo systemctl status kubelet | grep Active
# Expected: Active: active (running)
```

### 3.3 Check the worker registered correctly (on master)
```bash
kubectl describe node k8s-worker-1 | grep -A5 "Conditions:"
```

All conditions should show `Status: False` for pressure conditions and `Status: True` for `Ready`:
```
Conditions:
  Type                 Status
  MemoryPressure       False
  DiskPressure         False
  PIDPressure          False
  Ready                True
```

---

## STEP 4 — Repeat on Worker Node 2

Exit the Worker 1 terminal and SSH into **Worker Node 2**:

```bash
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<WORKER2_PUBLIC_IP>
```

Run the **same join command** (same token and hash work for multiple workers):

```bash
sudo kubeadm join 10.0.1.12:6443 \
  --token abcdef.1234567890abcdef \
  --discovery-token-ca-cert-hash sha256:abc123def456...
```

Verify on master:
```bash
kubectl get nodes
```

**Expected final state (all 3 nodes Ready):**
```
NAME           STATUS   ROLES           AGE   VERSION
k8s-master     Ready    control-plane   15m   v1.29.0
k8s-worker-1   Ready    <none>          5m    v1.29.0
k8s-worker-2   Ready    <none>          1m    v1.29.0
```

---

## STEP 5 — Final Cluster Verification (on master)

### 5.1 Nodes with full details
```bash
kubectl get nodes -o wide
```

Confirm each node has a unique `INTERNAL-IP` in the `10.0.1.x` range and shows `Ubuntu 22.04`.

### 5.2 All system pods running across all nodes
```bash
kubectl get pods -n kube-system -o wide
```

There should be a `calico-node-xxxxx` pod and `kube-proxy-xxxxx` pod on **each** node.

### 5.3 Schedule a test pod on each worker
```bash
kubectl create deployment verify-cluster \
  --image=nginx:alpine \
  --replicas=2

kubectl get pods -o wide
```

Both pods should be `Running` and distributed across `k8s-worker-1` and `k8s-worker-2` (not the master):
```
NAME                              READY   STATUS    NODE
verify-cluster-xxx-abc            1/1     Running   k8s-worker-1
verify-cluster-xxx-def            1/1     Running   k8s-worker-2
```

Clean up:
```bash
kubectl delete deployment verify-cluster
```

**Your cluster is fully operational.**

---

## Token Expiry — What to Do After 24 Hours

kubeadm join tokens expire after 24 hours. If a student runs `kubeadm join` the next day and gets a token error, generate a fresh command on the master:

```bash
sudo kubeadm token create --print-join-command
```

This prints a new, ready-to-paste join command with a fresh 24-hour token.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `nc -zv <master-ip> 6443` fails | Security group missing port 6443 | AWS Console → Security Group → add inbound TCP 6443 from `10.0.0.0/16` |
| `error: could not find a JWS signature` | Token is expired | Regenerate: `sudo kubeadm token create --print-join-command` |
| `x509: certificate has expired` | System clock mismatch | `sudo timedatectl set-ntp true` on the worker, then retry |
| Worker shows `NotReady` after 3 min | Calico not reaching the worker | Check `kubectl describe node k8s-worker-1` → Events section |
| `kubelet` not starting on worker | swap still enabled | `sudo swapoff -a` then `sudo systemctl restart kubelet` |
| Join succeeds but node never appears | Wrong master IP used | Verify `MASTER_IP` is the **private** IP, not the public IP |
