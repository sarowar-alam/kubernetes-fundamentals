# manifests — Kubernetes Resource Reference & Lab Guide

A progressive set of Kubernetes manifests covering the core resource types, with step-by-step apply/verify/cleanup instructions for each. Apply manifests against any working cluster — kubeadm (lab-01) or EKS (lab-02).

---

## Directory Layout

```
manifests/
├── 01-pod/
│   ├── pod-basic.yaml          # Single-container nginx pod
│   └── pod-debug.yaml          # Multi-container pod (main + sidecar)
├── 02-replicaset/
│   └── replicaset.yaml         # Self-healing nginx replica set (3 replicas)
├── 03-deployment/
│   └── deployment.yaml         # Rolling-update deployment with history
├── 04-service/
│   ├── service-clusterip.yaml  # Internal-only service
│   ├── service-nodeport.yaml   # External access via node port
│   └── service-loadbalancer.yaml # AWS NLB (EKS only)
├── 05-namespace/
│   └── namespace.yaml          # dev + staging namespace isolation
└── 06-static-site/
    ├── configmap.yaml          # HTML page stored as ConfigMap
    ├── deployment.yaml         # 2-replica nginx:alpine deployment
    ├── service-nodeport.yaml   # NodePort 30090 (kubeadm + EKS)
    └── service-loadbalancer.yaml # AWS NLB public endpoint (EKS only)
```

**Recommended apply order:** 01 → 02 → 03 → 04 → 05 → 06. Each section builds on the previous.

---

## Prerequisites

A running Kubernetes cluster with `kubectl` configured:

```bash
kubectl cluster-info          # control plane must respond
kubectl get nodes             # at least one node must be Ready
```

---

## 01 — Pod

A Pod is the smallest deployable unit in Kubernetes — one or more containers sharing a network and storage.

### pod-basic.yaml

A single nginx container with CPU/memory resource limits.

```bash
# Apply
kubectl apply -f manifests/01-pod/pod-basic.yaml

# Verify
kubectl get pods
kubectl describe pod nginx-basic

# Stream logs
kubectl logs nginx-basic -f

# Open a shell inside the container
kubectl exec -it nginx-basic -- /bin/sh

# Cleanup
kubectl delete -f manifests/01-pod/pod-basic.yaml
```

**Key concepts in this manifest:**
- `resources.requests` — minimum CPU/memory the scheduler must find on a node before placing the pod
- `resources.limits` — hard ceiling; exceeding CPU causes throttling, exceeding memory causes OOMKill
- `labels` — key-value metadata; Services use these to select which pods receive traffic

---

### pod-debug.yaml

A two-container pod: a main nginx container and a busybox sidecar that writes periodic log entries. Demonstrates the multi-container (sidecar) pattern.

```bash
# Apply
kubectl apply -f manifests/01-pod/pod-debug.yaml

# Watch pod start
kubectl get pods -w

# Shell into the main container
kubectl exec -it nginx-debug -c nginx -- /bin/sh

# Shell into the sidecar
kubectl exec -it nginx-debug -c logger -- /bin/sh

# Logs from each container separately
kubectl logs nginx-debug -c nginx
kubectl logs nginx-debug -c logger

# Full describe (events, container statuses, resource limits)
kubectl describe pod nginx-debug

# Cleanup
kubectl delete -f manifests/01-pod/pod-debug.yaml
```

**Why the sidecar pattern matters:**
Sidecars share the pod's network namespace — they communicate via `localhost`. Common real-world sidecars: log shippers (Fluentd), service mesh proxies (Envoy/Istio), secrets injectors (Vault Agent).

---

## 02 — ReplicaSet

A ReplicaSet continuously reconciles the number of running pods to match `spec.replicas`. If a pod dies, a replacement is created. If extra pods appear with matching labels, they are deleted.

### replicaset.yaml

Maintains 3 nginx replicas. Demonstrates self-healing and manual scaling.

```bash
# Apply
kubectl apply -f manifests/02-replicaset/replicaset.yaml

# Verify — all 3 pods Running
kubectl get rs
kubectl get pods --show-labels

# Self-healing demo — open a watcher in one terminal:
kubectl get pods -w

# In another terminal, delete a pod:
kubectl delete pod <one-of-the-pod-names>
# Watch: a replacement pod appears within seconds

# Scale to 5 replicas
kubectl scale rs nginx-rs --replicas=5
kubectl get pods

# Scale back to 2
kubectl scale rs nginx-rs --replicas=2

# Cleanup
kubectl delete -f manifests/02-replicaset/replicaset.yaml
```

> **Production note:** You rarely create ReplicaSets directly. Use a Deployment instead — it manages a ReplicaSet for you and adds rolling updates and rollback history on top.

---

## 03 — Deployment

A Deployment wraps a ReplicaSet and adds:
- **Rolling updates** — replace pods one by one with zero downtime
- **Rollback history** — revert to any previous revision with one command
- **Pause/resume** — hold a rollout mid-way to verify before continuing

### deployment.yaml

3-replica nginx deployment with `RollingUpdate` strategy (`maxSurge: 1`, `maxUnavailable: 0` — zero downtime).

```bash
# Apply
kubectl apply -f manifests/03-deployment/deployment.yaml

# Verify
kubectl get deployments
kubectl get pods -o wide
kubectl rollout history deployment/nginx-deployment
```

---

### Rolling Update

```bash
# Update the image
kubectl set image deployment/nginx-deployment nginx=nginx:1.25

# Annotate the reason (shows up in rollout history)
kubectl annotate deployment/nginx-deployment \
  kubernetes.io/change-cause="Updated nginx from alpine to 1.25" \
  --overwrite

# Watch the rollout
kubectl rollout status deployment/nginx-deployment

# Check history (should now show 2 revisions)
kubectl rollout history deployment/nginx-deployment
```

Expected rollout output:
```
Waiting for deployment "nginx-deployment" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deployment" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "nginx-deployment" successfully rolled out
```

---

### Simulate a Bad Deploy

```bash
# Push a non-existent image tag
kubectl set image deployment/nginx-deployment nginx=nginx:DOES-NOT-EXIST
kubectl annotate deployment/nginx-deployment \
  kubernetes.io/change-cause="Bad deploy — wrong image tag" \
  --overwrite

# Watch pods fail
kubectl get pods -w
# Pods show: ErrImagePull → ImagePullBackOff
```

> **Why existing pods are not killed:** `maxUnavailable: 0` means the Deployment will not terminate an old pod until a new one is healthy. Your live version keeps serving traffic during a bad deploy.

---

### Rollback

```bash
# Rollback to the previous revision (immediate fix)
kubectl rollout undo deployment/nginx-deployment

# Watch recovery
kubectl rollout status deployment/nginx-deployment

# Rollback to a specific revision (e.g. revision 1)
kubectl rollout history deployment/nginx-deployment
kubectl rollout undo deployment/nginx-deployment --to-revision=1

# Confirm which image is now running
kubectl describe deployment nginx-deployment | grep Image
```

---

### Pause and Resume

Useful for canary-style validation mid-rollout:

```bash
kubectl rollout pause deployment/nginx-deployment
# ... inspect pods, run smoke tests ...
kubectl rollout resume deployment/nginx-deployment
```

---

### Scaling

```bash
kubectl scale deployment nginx-deployment --replicas=5
kubectl scale deployment nginx-deployment --replicas=2
```

---

### Rollout Command Reference

| Task | Command |
|---|---|
| View history | `kubectl rollout history deployment/<name>` |
| Trigger update | `kubectl set image deployment/<name> <container>=<image>` |
| Watch progress | `kubectl rollout status deployment/<name>` |
| Rollback (last) | `kubectl rollout undo deployment/<name>` |
| Rollback (specific) | `kubectl rollout undo deployment/<name> --to-revision=N` |
| Pause rollout | `kubectl rollout pause deployment/<name>` |
| Resume rollout | `kubectl rollout resume deployment/<name>` |

---

### Cleanup

```bash
kubectl delete -f manifests/03-deployment/deployment.yaml
```

---

## 04 — Service

A Service gives pods a stable network identity — a fixed DNS name and IP. Pods come and go; the Service endpoint stays constant. The `selector` field determines which pods receive traffic.

**Requires the Deployment from section 03:**

```bash
kubectl apply -f manifests/03-deployment/deployment.yaml
```

---

### service-clusterip.yaml — Internal only

```bash
kubectl apply -f manifests/04-service/service-clusterip.yaml

# Verify
kubectl get svc nginx-clusterip-svc
kubectl describe svc nginx-clusterip-svc

# Test from inside the cluster (ClusterIP has no external access)
kubectl run test-pod --image=busybox --restart=Never --rm -it -- /bin/sh
# Inside the shell:
wget -qO- http://nginx-clusterip-svc
exit

# Cleanup
kubectl delete -f manifests/04-service/service-clusterip.yaml
```

**When to use:** Database connections, backend APIs, any service that must not be internet-accessible. DNS name inside the cluster: `nginx-clusterip-svc.default.svc.cluster.local`.

---

### service-nodeport.yaml — Node-level external access

```bash
kubectl apply -f manifests/04-service/service-nodeport.yaml

# Verify — find the nodePort
kubectl get svc nginx-nodeport-svc

# Get a node's external IP
kubectl get nodes -o wide

# Access in browser or curl
curl http://<node-public-ip>:30080

# Cleanup
kubectl delete -f manifests/04-service/service-nodeport.yaml
```

**When to use:** Development, demos, kubeadm clusters where a LoadBalancer type doesn't work. **Avoid in production** — opens ports on every node, non-standard port range (30000–32767).

---

### service-loadbalancer.yaml — AWS NLB (EKS only)

> **Only works on EKS.** On kubeadm the `EXTERNAL-IP` stays `<pending>` — no cloud controller is present.

```bash
kubectl apply -f manifests/04-service/service-loadbalancer.yaml

# Watch for the NLB DNS name to appear (takes ~90 seconds)
kubectl get svc nginx-lb-svc -w

# Test once EXTERNAL-IP is populated
curl http://<EXTERNAL-IP>

# Cleanup — also deletes the AWS NLB
kubectl delete -f manifests/04-service/service-loadbalancer.yaml
```

**Cost note:** Each LoadBalancer service provisions one AWS NLB (~$0.008/hr). For exposing multiple services, use an Ingress controller to share a single NLB.

---

### Service Type Comparison

| Type | Access | Use case |
|---|---|---|
| `ClusterIP` | In-cluster only | Databases, internal APIs |
| `NodePort` | `<node-ip>:<port>` from anywhere | Dev/demo, kubeadm clusters |
| `LoadBalancer` | Public DNS/IP via cloud LB | Production on EKS/GKE/AKS |

---

## 05 — Namespace

A Namespace is a virtual cluster within a cluster — it scopes resource names, applies quotas, and isolates teams or environments from each other.

### namespace.yaml

Creates `dev` and `staging` namespaces.

```bash
# Apply
kubectl apply -f manifests/05-namespace/namespace.yaml

# Verify
kubectl get namespaces

# Deploy the nginx deployment into the dev namespace
kubectl apply -f manifests/03-deployment/deployment.yaml -n dev

# List pods in dev
kubectl get pods -n dev

# Confirm staging is isolated (no pods)
kubectl get pods -n staging

# Set dev as your default namespace for the session
kubectl config set-context --current --namespace=dev
kubectl get pods    # now shows dev pods without -n flag

# Reset to default namespace
kubectl config set-context --current --namespace=default

# Cleanup — deletes namespaces AND all resources inside them
kubectl delete -f manifests/05-namespace/namespace.yaml
```

**Real-world patterns:**
- One namespace per environment: `dev`, `staging`, `production`
- One namespace per team: `frontend`, `backend`, `data`
- Combine with `ResourceQuota` to cap CPU/memory per namespace
- `NetworkPolicy` can restrict cross-namespace traffic

---

## 06 — Static Site (Kubernetes Learning Hub)

A self-contained static website served by `nginx:alpine`, delivered to the browser via a NodePort Service on port **30090**. No Docker build required — the HTML page is stored in a ConfigMap and mounted directly into the container.

### Resource map

| File | Kind | Name |
|---|---|---|
| `configmap.yaml` | ConfigMap | `static-site-html` |
| `deployment.yaml` | Deployment | `static-site` (2 replicas) |
| `service-nodeport.yaml` | Service/NodePort | `static-site-nodeport` (port 30090) |
| `service-loadbalancer.yaml` | Service/LoadBalancer | `static-site-lb` (EKS only) |

### Apply

Apply in order (ConfigMap must exist before the Deployment mounts it):

```bash
kubectl apply -f manifests/06-static-site/configmap.yaml
kubectl apply -f manifests/06-static-site/deployment.yaml
kubectl apply -f manifests/06-static-site/service-nodeport.yaml
# EKS only:
kubectl apply -f manifests/06-static-site/service-loadbalancer.yaml

# Or apply the entire folder at once
kubectl apply -f manifests/06-static-site/
```

### Verify

```bash
kubectl get configmap static-site-html
kubectl get deployment static-site
kubectl get pods -l app=static-site
kubectl get svc static-site-nodeport
```

Expected pod output — both pods must be `Running 1/1`:
```
NAME                           READY   STATUS    RESTARTS   AGE
static-site-7d9b5c6f8-abc12   1/1     Running   0          30s
static-site-7d9b5c6f8-xyz99   1/1     Running   0          30s
```

### Access the site

**kubeadm (lab-01-kubeadm) — NodePort**

```bash
# Get a node's external IP
kubectl get nodes -o wide

# Open in browser or curl
curl http://<node-public-ip>:30090
```

> Ensure the EC2 security group for your kubeadm nodes allows **inbound TCP 30090** from your IP. Add a custom inbound rule in the AWS console (EC2 → Security Groups → Inbound rules → Add rule: Custom TCP, Port 30090, Source: My IP).

**EKS (lab-02-eks) — LoadBalancer (recommended)**

EKS worker nodes are in private subnets and have no public IP. Use the LoadBalancer service to get a public AWS NLB endpoint:

```bash
# Apply the LoadBalancer service
kubectl apply -f manifests/06-static-site/service-loadbalancer.yaml

# Watch until EXTERNAL-IP is populated (~60-90 seconds)
kubectl get svc static-site-lb -w

# Once EXTERNAL-IP shows a DNS name:
curl http://<EXTERNAL-IP>
```

Cleanup (also deletes the NLB):
```bash
kubectl delete -f manifests/06-static-site/service-loadbalancer.yaml
```

**EKS — alternative: port-forward (no AWS changes needed)**

```bash
kubectl port-forward svc/static-site-nodeport 8080:80
# Open http://localhost:8080 in your browser
```

### Update the site in-place

Because content lives in a ConfigMap, you can redeploy the page without rebuilding any image:

```bash
# Edit the HTML
kubectl edit configmap static-site-html

# Restart pods to pick up the updated ConfigMap
kubectl rollout restart deployment/static-site

# Watch the rolling restart
kubectl rollout status deployment/static-site
```

### Cleanup

```bash
kubectl delete -f manifests/06-static-site/
```

---

## Full Sequence — Apply Everything

To bring up all resources in order:

```bash
kubectl apply -f manifests/01-pod/pod-basic.yaml
kubectl apply -f manifests/01-pod/pod-debug.yaml
kubectl apply -f manifests/02-replicaset/replicaset.yaml
kubectl apply -f manifests/03-deployment/deployment.yaml
kubectl apply -f manifests/04-service/service-clusterip.yaml
kubectl apply -f manifests/04-service/service-nodeport.yaml
# EKS only:
kubectl apply -f manifests/04-service/service-loadbalancer.yaml
kubectl apply -f manifests/05-namespace/namespace.yaml
kubectl apply -f manifests/06-static-site/
```

---

## Full Sequence — Tear Everything Down

```bash
kubectl delete -f manifests/06-static-site/
kubectl delete -f manifests/05-namespace/namespace.yaml
kubectl delete -f manifests/04-service/
kubectl delete -f manifests/03-deployment/deployment.yaml
kubectl delete -f manifests/02-replicaset/replicaset.yaml
kubectl delete -f manifests/01-pod/
```

---

## Quick Diagnostic Commands

```bash
# All resources in the current namespace
kubectl get all

# Events (most useful for debugging failed pods)
kubectl get events --sort-by='.lastTimestamp'

# Why is a pod not starting?
kubectl describe pod <pod-name>
kubectl logs <pod-name>
kubectl logs <pod-name> --previous   # logs from a crashed container

# Why is a node NotReady?
kubectl describe node <node-name>

# What labels does a pod have?
kubectl get pods --show-labels

# Which pods does a service select?
kubectl get pods -l app=nginx
```

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
