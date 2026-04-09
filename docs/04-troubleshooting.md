# Kubernetes Troubleshooting Guide

A systematic field guide for diagnosing and fixing common Kubernetes failures.  
Each section follows the same pattern: **Symptoms → Diagnose → Root Cause → Fix**.

---

## Table of Contents

1. [CrashLoopBackOff](#1-crashloopbackoff)
2. [ImagePullBackOff / ErrImagePull](#2-imagepullbackoff--errimagepull)
3. [Pod Stuck in Pending](#3-pod-stuck-in-pending)
4. [OOMKilled — Out of Memory](#4-oomkilled--out-of-memory)
5. [Service Not Reachable / DNS Failure](#5-service-not-reachable--dns-failure)
6. [Node NotReady](#6-node-notready)

---

## 1. CrashLoopBackOff

### Symptoms
```
NAME          READY   STATUS             RESTARTS   AGE
my-app-xyz    0/1     CrashLoopBackOff   5          3m
```
The pod starts, crashes immediately, and Kubernetes keeps restarting it with exponential backoff (10s → 20s → 40s → … up to 5 min).

### Diagnose
```bash
# Step 1 — Check the current status and restart count
kubectl get pods

# Step 2 — Read the last crash logs (most useful step)
kubectl logs <pod-name>

# Step 3 — Read logs from the PREVIOUS container run (before latest restart)
kubectl logs <pod-name> --previous

# Step 4 — Inspect events for lifecycle clues
kubectl describe pod <pod-name>
# Look for: "Back-off restarting failed container", exit codes, OOMKilled

# Step 5 — Check the exit code
kubectl get pod <pod-name> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
```

### Common Root Causes and Fixes

| Exit Code | Meaning | Fix |
|-----------|---------|-----|
| `1` | Application error (unhandled exception, missing config) | Fix the app code or supply missing env vars / ConfigMaps |
| `2` | Misuse of shell built-in | Correct the entrypoint / command in the pod spec |
| `127` | Command not found | Wrong image or wrong `command:` in spec |
| `132` / `134` | Illegal instruction / SIGABRT | Wrong CPU architecture (e.g., arm image on amd64 node) |
| `137` | OOMKilled (SIGKILL) | Increase memory limit — see Section 4 |
| `143` | SIGTERM — graceful shutdown not handled | Fix app shutdown logic or increase `terminationGracePeriodSeconds` |

```bash
# Fix example: inject a missing env var from a ConfigMap
kubectl edit deployment my-app
# Add under spec.template.spec.containers[0]:
#   env:
#     - name: DB_HOST
#       valueFrom:
#         configMapKeyRef:
#           name: app-config
#           key: DB_HOST
```

---

## 2. ImagePullBackOff / ErrImagePull

### Symptoms
```
NAME          READY   STATUS             RESTARTS   AGE
my-app-xyz    0/1     ImagePullBackOff   0          2m
my-app-abc    0/1     ErrImagePull       0          1m
```
`ErrImagePull` is the first failure. After retries it becomes `ImagePullBackOff`.

### Diagnose
```bash
# Step 1 — Find the exact error message
kubectl describe pod <pod-name>
# Look for the "Events" section at the bottom:
#   Failed to pull image "myrepo/myapp:v2.1": ... 404 Not Found
#   Failed to pull image "myrepo/myapp:v2.1": ... no basic auth credentials

# Step 2 — Confirm the image name and tag in the spec
kubectl get pod <pod-name> -o jsonpath='{.spec.containers[*].image}'
```

### Common Root Causes and Fixes

**Wrong image name or tag (typo, tag does not exist)**
```bash
# Fix: correct the image reference
kubectl set image deployment/my-app my-app=nginx:1.25.3
# or edit the Deployment directly
kubectl edit deployment my-app
```

**Private registry — missing imagePullSecret**
```bash
# Step 1 — Create a registry credential Secret
kubectl create secret docker-registry regcred \
  --docker-server=<registry-url> \
  --docker-username=<username> \
  --docker-password=<password>

# Step 2 — Reference it in the Deployment spec
# Under spec.template.spec:
#   imagePullSecrets:
#     - name: regcred
kubectl patch deployment my-app \
  -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}}}'
```

**Node cannot reach the registry (network / firewall)**
```bash
# Test DNS resolution from a node (kubeadm clusters)
kubectl run debug --image=busybox --rm -it --restart=Never -- \
  nslookup registry-1.docker.io

# Check node security group / IAM role (EKS)
# Worker nodes need:
#   - Outbound 443 to docker.io / ghcr.io / public.ecr.aws
#   - ECR pull: AmazonEC2ContainerRegistryReadOnly IAM policy
```

---

## 3. Pod Stuck in Pending

### Symptoms
```
NAME          READY   STATUS    RESTARTS   AGE
my-app-xyz    0/1     Pending   0          10m
```
Pod is created but never scheduled onto a node.

### Diagnose
```bash
# Step 1 — Read the Events section — it almost always tells you why
kubectl describe pod <pod-name>

# Step 2 — Check available node resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Step 3 — Check if nodes are Ready
kubectl get nodes

# Step 4 — List taints on nodes (may repel the pod)
kubectl describe nodes | grep -i taint
```

### Common Root Causes and Fixes

**Insufficient CPU or memory on all nodes**
```
0/2 nodes are available: 2 Insufficient memory.
```
```bash
# Option A — Reduce resource requests in the Deployment
kubectl edit deployment my-app
# Lower spec.template.spec.containers[0].resources.requests

# Option B — Add more nodes (EKS: scale the node group)
eksctl scale nodegroup --cluster=<name> --name=<ng-name> --nodes=3
```

**PersistentVolumeClaim not bound**
```
0/2 nodes are available: 2 pod has unbound immediate PersistentVolumeClaims.
```
```bash
kubectl get pvc       # look for STATUS = Pending
kubectl describe pvc <pvc-name>
# Common fix: StorageClass not present / provisioner not installed
kubectl get storageclass
```

**NodeSelector / affinity / tolerations mismatch**
```
0/2 nodes are available: 2 node(s) didn't match Pod's node affinity/selector.
```
```bash
# Check what labels the nodes have
kubectl get nodes --show-labels

# Check what the pod requires
kubectl get pod <pod-name> -o jsonpath='{.spec.nodeSelector}'

# Fix: either label the node or remove the nodeSelector
kubectl label node <node-name> disktype=ssd
```

---

## 4. OOMKilled — Out of Memory

### Symptoms
```
NAME          READY   STATUS      RESTARTS   AGE
my-app-xyz    0/1     OOMKilled   2          8m
```
Or inside `kubectl describe pod`:
```
Last State:  Terminated
  Reason: OOMKilled
  Exit Code: 137
```

### Diagnose
```bash
# Step 1 — Confirm OOMKilled
kubectl describe pod <pod-name>
# Look for: Reason: OOMKilled, Exit Code: 137

# Step 2 — Check current memory limit
kubectl get pod <pod-name> -o jsonpath=\
'{.spec.containers[0].resources.limits.memory}'

# Step 3 — Check actual memory usage
kubectl top pod <pod-name>           # requires metrics-server
kubectl top pod <pod-name> --containers
```

### Fix

```bash
# Increase the memory limit in the Deployment
kubectl edit deployment my-app
# Change:
#   resources:
#     limits:
#       memory: "128Mi"   ← too low
# To:
#   resources:
#     limits:
#       memory: "256Mi"   ← give the app room to breathe

# Apply a patch non-interactively
kubectl patch deployment my-app --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"256Mi"}]'
```

**Best practice:** Set `requests` to the app's idle footprint and `limits` to its peak footprint plus ~20% headroom. Use `kubectl top` data from a realistic load test to determine these values.

---

## 5. Service Not Reachable / DNS Failure

### Symptoms
- `curl http://<service-name>` times out from inside the cluster
- `nslookup <service-name>` returns `NXDOMAIN` or `server can't find`
- Browser cannot reach NodePort / LoadBalancer externally

### Diagnose

**Step 1 — Verify the Service exists and has endpoints**
```bash
kubectl get svc <service-name>
kubectl get endpoints <service-name>
# IMPORTANT: if ENDPOINTS shows <none>, the selector doesn't match any pods
```

**Step 2 — Check that the selector matches pod labels**
```bash
# Get the Service selector
kubectl get svc <service-name> -o jsonpath='{.spec.selector}'
# e.g. {"app":"my-app"}

# Find pods that match it
kubectl get pods -l app=my-app
# If this returns nothing → label mismatch → fix the selector or the pod labels
```

**Step 3 — Test DNS resolution from inside the cluster**
```bash
kubectl run dns-test --image=busybox --rm -it --restart=Never -- \
  nslookup <service-name>
# Full FQDN: <service-name>.<namespace>.svc.cluster.local
kubectl run dns-test --image=busybox --rm -it --restart=Never -- \
  nslookup <service-name>.default.svc.cluster.local
```

**Step 4 — Test direct pod connectivity (bypass Service)**
```bash
kubectl get pods -l app=my-app -o wide   # get pod IP
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl http://<pod-ip>:<container-port>
```

**Step 5 — Check CoreDNS is running**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### Common Fixes

| Problem | Fix |
|---------|-----|
| `endpoints: <none>` | Fix `spec.selector` in Service to match pod `labels` |
| Wrong `targetPort` | Match `targetPort` in Service to `containerPort` in Deployment |
| DNS returning NXDOMAIN | Restart CoreDNS: `kubectl rollout restart deployment/coredns -n kube-system` |
| NodePort not reachable | Check node Security Group allows inbound TCP on the NodePort (30000–32767) |
| LoadBalancer pending | On kubeadm, no cloud controller — use NodePort instead |

---

## 6. Node NotReady

### Symptoms
```
NAME             STATUS     ROLES    AGE
ip-10-0-1-101    NotReady   <none>   2d
```

### Diagnose
```bash
# Step 1 — Describe the node for events and conditions
kubectl describe node <node-name>
# Look for the "Conditions" section:
#   MemoryPressure, DiskPressure, PIDPressure, Ready

# Step 2 — Check node conditions in JSON
kubectl get node <node-name> -o jsonpath='{.status.conditions[*].message}'

# Step 3 — SSH into the node and check the kubelet
# (kubeadm cluster — EC2 SSH)
systemctl status kubelet
journalctl -u kubelet -n 50 --no-pager

# Step 4 — Check container runtime
systemctl status containerd
crictl ps       # list running containers on the node
```

### Common Root Causes and Fixes

**kubelet stopped / crashed**
```bash
# On the node via SSH
systemctl restart kubelet
journalctl -u kubelet -f   # watch for errors after restart
```

**Disk pressure — node filesystem full**
```bash
# Check disk usage on the node
df -h
# Free space: prune unused container images
crictl rmi --prune

# Kubernetes will evict pods when disk hits the eviction threshold (~85%)
# Long-term fix: increase EBS volume size or add a dedicated data disk
```

**Memory pressure — node OOM**
```bash
# Check memory on the node
free -h
# Review which pods are consuming the most memory
kubectl top pods --all-namespaces --sort-by=memory | head -20
# Reduce memory limits on top consumers or add more nodes
```

**Network plugin not running (kubeadm)**
```bash
# Check that Calico / Flannel / Weave pods are Running
kubectl get pods -n kube-system
# If CNI pods are CrashLoopBackOff, reinstall the CNI manifest:
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

**Node lost contact with control plane (EC2 firewall / SG)**
```bash
# From the node, test API server connectivity
curl -k https://<control-plane-ip>:6443/healthz
# If connection refused: open TCP 6443 in the control-plane Security Group
#   inbound from worker node SG / CIDR
```

---

## General Debugging Commands

```bash
# --- Pod Lifecycle ---
kubectl get pods -o wide                          # include node assignment
kubectl get pods --all-namespaces                 # across all namespaces
kubectl describe pod <pod-name>                   # full event history
kubectl logs <pod-name>                           # current container logs
kubectl logs <pod-name> --previous                # logs from last crash
kubectl logs <pod-name> -c <container-name>       # multi-container pod
kubectl logs <pod-name> -f                        # follow / tail logs

# --- Interactive Debugging ---
kubectl exec -it <pod-name> -- sh                 # shell into container
kubectl exec -it <pod-name> -c <container> -- sh  # specific container
kubectl run debug --image=busybox --rm -it --restart=Never -- sh

# --- Resource Inspection ---
kubectl get all                                   # pods, svc, deploy, rs
kubectl get events --sort-by='.lastTimestamp'     # cluster-wide event log
kubectl top nodes                                 # node CPU/mem (needs metrics-server)
kubectl top pods --all-namespaces                 # pod CPU/mem

# --- Service / Network ---
kubectl get endpoints                             # pod IPs behind each Service
kubectl port-forward pod/<pod-name> 8080:80       # local → pod tunnel
kubectl port-forward svc/<svc-name> 8080:80       # local → service tunnel

# --- Rollout ---
kubectl rollout status deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>

# --- Dry-run / Diff ---
kubectl apply -f manifest.yaml --dry-run=client   # validate without applying
kubectl diff -f manifest.yaml                      # what would change
```

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
