# Master Node Initialization — Manual Execution Guide

**Companion to:** `master-init.sh`  
**Run on:** Master Node only  
**Pre-requisite:** `install-kubeadm-node.sh` must have completed successfully on this node

---

## Overview

This guide walks you through every command in `master-init.sh` manually — one step at a time — with verification checks after each stage.

```
STEP 1 → kubeadm init        (bootstrap control plane)
STEP 2 → kubectl config      (set up CLI access)
STEP 3 → Calico CNI          (enable pod networking)
STEP 4 → Copy join command   (for worker nodes)
STEP 5 → Verify cluster      (confirm everything is healthy)
```

---

## Before You Start

SSH into the **master node**:
```bash
ssh -i ~/.ssh/k8s-lab-key.pem ubuntu@<MASTER_PUBLIC_IP>
```

Confirm you are on the correct machine:
```bash
hostname
# Expected: k8s-master
```

Confirm kubeadm is installed:
```bash
kubeadm version
# Expected: kubeadm version: &version.Info{GitVersion:"v1.29.x", ...}
```

Confirm swap is disabled (required by Kubernetes):
```bash
free -h | grep Swap
# Expected:
# Swap:          0B         0B         0B
```

---

## STEP 1 — Initialize the Control Plane

### 1.1 Get the master node's private IP

```bash
MASTER_PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo $MASTER_PRIVATE_IP
```

**Expected output:** A private IP in the `10.0.x.x` range (your VPC subnet)

> This is the IP worker nodes use to reach the API server. Always use the **private** IP here — not the public IP. The public IP can change; the private IP stays stable within the VPC.

---

### 1.2 Run kubeadm init

```bash
sudo kubeadm init \
  --apiserver-advertise-address=${MASTER_PRIVATE_IP} \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=1.29.0 \
  --ignore-preflight-errors=NumCPU \
  | tee /tmp/kubeadm-init.log
```

**What each flag does:**

| Flag | Purpose |
|---|---|
| `--apiserver-advertise-address` | The IP the API server binds to and advertises to other nodes |
| `--pod-network-cidr=192.168.0.0/16` | IP range for pods — must match Calico's expected range |
| `--kubernetes-version=1.29.0` | Pin the version to avoid unexpected upgrades |
| `--ignore-preflight-errors=NumCPU` | t3.medium has 2 vCPU; K8s recommends 2+ but warns — this suppresses the warning |
| `tee /tmp/kubeadm-init.log` | Saves the full output (we need the join command from it later) |

**This takes 2–3 minutes.** You will see output like:
```
[init] Using Kubernetes version: v1.29.0
[preflight] Running pre-flight checks
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] Generating "etcd/ca" certificate and key
...
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!
```

### ✅ Verification — STEP 1

At the very end of the output, you will see a block like this:
```
Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 10.0.1.x:6443 --token abcdef.1234567890abcdef \
        --discovery-token-ca-cert-hash sha256:abc123...
```

**Copy and save this entire `kubeadm join` command.** You will need it in the worker guide.

> If you miss it, you can regenerate it later:
> ```bash
> sudo kubeadm token create --print-join-command
> ```

---

## STEP 2 — Configure kubectl

kubeadm writes the cluster credentials to `/etc/kubernetes/admin.conf` (root only).  
We copy it to the `ubuntu` user's home so you don't need `sudo` for every `kubectl` command.

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### ✅ Verification — STEP 2

```bash
kubectl get nodes
```

**Expected output:**
```
NAME         STATUS     ROLES           AGE   VERSION
k8s-master   NotReady   control-plane   1m    v1.29.0
```

`NotReady` is **normal at this point** — the CNI plugin is not installed yet. The node will become `Ready` after Step 3.

Also verify you can see the cluster info:
```bash
kubectl cluster-info
```

Expected:
```
Kubernetes control plane is running at https://10.0.1.x:6443
CoreDNS is running at https://10.0.1.x:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

---

## STEP 3 — Install Calico CNI

Pods in Kubernetes cannot communicate with each other until a **CNI (Container Network Interface)** plugin is installed. Calico is the CNI we use — it's production-grade and supports Network Policies.

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

**Expected output:**
```
poddisruptionbudget.policy/calico-kube-controllers created
serviceaccount/calico-kube-controllers created
serviceaccount/calico-node created
configmap/calico-config created
...
daemonset.apps/calico-node created
deployment.apps/calico-kube-controllers created
```

### ✅ Verification — STEP 3

Watch the Calico pods start up:
```bash
watch kubectl get pods -n kube-system
```

Wait until all `calico-*` pods show `Running`. This takes about 60 seconds. Press `Ctrl+C` when done.

```
NAME                                       READY   STATUS    RESTARTS   AGE
calico-kube-controllers-xxx                1/1     Running   0          60s
calico-node-xxxxx                          1/1     Running   0          60s
coredns-xxx                                1/1     Running   0          3m
coredns-xxx                                1/1     Running   0          3m
etcd-k8s-master                            1/1     Running   0          3m
kube-apiserver-k8s-master                  1/1     Running   0          3m
kube-controller-manager-k8s-master         1/1     Running   0          3m
kube-proxy-xxxxx                           1/1     Running   0          3m
kube-scheduler-k8s-master                  1/1     Running   0          3m
```

Now check that the master node is `Ready`:
```bash
kubectl get nodes
```

**Expected output:**
```
NAME         STATUS   ROLES           AGE   VERSION
k8s-master   Ready    control-plane   5m    v1.29.0
```

---

## STEP 4 — Retrieve the Worker Join Command

The join command was printed at the end of `kubeadm init`. If you need to retrieve it again:

```bash
# Option A: Read from the saved log
tail -5 /tmp/kubeadm-init.log
```

```bash
# Option B: Generate a fresh token (tokens expire after 24h)
sudo kubeadm token create --print-join-command
```

**Example output:**
```
kubeadm join 10.0.1.12:6443 --token abcdef.1234567890abcdef \
        --discovery-token-ca-cert-hash sha256:abc123def456...
```

**Save this command.** Give it to students to run on their worker nodes using `worker-join-guide.md`.

---

## STEP 5 — Full Cluster Health Check

Run these after both worker nodes have joined (see `worker-join-guide.md`):

### 5.1 All nodes visible and Ready
```bash
kubectl get nodes -o wide
```

Expected (all three nodes `Ready`):
```
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE
k8s-master     Ready    control-plane   10m   v1.29.0   10.0.1.x      Ubuntu 22.04
k8s-worker-1   Ready    <none>          3m    v1.29.0   10.0.1.x      Ubuntu 22.04
k8s-worker-2   Ready    <none>          2m    v1.29.0   10.0.1.x      Ubuntu 22.04
```

### 5.2 All system pods healthy
```bash
kubectl get pods -n kube-system
```

All pods should show `Running`. No pod should be in `CrashLoopBackOff` or `Pending`.

### 5.3 Control plane component status
```bash
kubectl get componentstatuses
```

Expected:
```
NAME                 STATUS    MESSAGE   ERROR
controller-manager   Healthy   ok
scheduler            Healthy   ok
etcd-0               Healthy   ok
```

### 5.4 API server is responding
```bash
kubectl get namespaces
```

Expected:
```
NAME              STATUS   AGE
default           Active   10m
kube-node-lease   Active   10m
kube-public       Active   10m
kube-system       Active   10m
```

### 5.5 Deploy a test pod to confirm scheduling works
```bash
kubectl run test-nginx --image=nginx:alpine
kubectl get pods -o wide
```

Expected: Pod is `Running` on one of the **worker** nodes (not the master):
```
NAME         READY   STATUS    NODE
test-nginx   1/1     Running   k8s-worker-1
```

Clean up:
```bash
kubectl delete pod test-nginx
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubeadm init` fails with `swap is enabled` | Swap not disabled | `sudo swapoff -a` then retry |
| `kubeadm init` fails with `port 6443 in use` | Previous cluster exists | `sudo kubeadm reset -f` then retry |
| `kubectl get nodes` → `refused` | kubeconfig not copied | Re-run the 3 copy commands in Step 2 |
| Master stays `NotReady` after 3 min | Calico not applied | Check `kubectl get pods -n kube-system` for errors |
| Calico pods in `Init` for >5 min | Image pull slow | Wait; or check internet: `curl -I https://docker.io` |
| `kubectl get componentstatuses` shows `Unhealthy` | Control plane not fully started | Wait 2 min and retry; check `journalctl -u kubelet` |
