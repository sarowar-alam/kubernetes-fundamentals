# Kubernetes Components — Internal Engineering Deep Dive

How a `kubectl apply` becomes a running container: a complete walkthrough of every Kubernetes component, what it does, how it connects to every other component, and why it is designed the way it is.

---

## Component Map

```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                          CONTROL PLANE                                  │
  │                                                                         │
  │   ┌──────────────┐     ┌──────────┐     ┌──────────────────────────┐   │
  │   │   kubectl    │────▶│  kube-   │────▶│          etcd            │   │
  │   │  (client)    │     │apiserver │◀────│  (distributed key-value  │   │
  │   └──────────────┘     │  :6443   │     │   store — source of      │   │
  │                        └────┬─────┘     │   truth for all state)   │   │
  │                             │           └──────────────────────────┘   │
  │                    ┌────────┴────────┐                                  │
  │                    │                 │                                  │
  │             ┌──────▼──────┐  ┌───────▼──────────────┐                  │
  │             │   kube-     │  │   kube-controller-   │                  │
  │             │  scheduler  │  │      manager         │                  │
  │             └─────────────┘  │  (Deployment ctrl)   │                  │
  │                              │  (ReplicaSet ctrl)   │                  │
  │                              │  (Node ctrl)         │                  │
  │                              │  (Endpoint ctrl)     │                  │
  │                              └──────────────────────┘                  │
  └─────────────────────────────────────────────────────────────────────────┘
              │                           │
              │ watch loop                │ watch loop
              ▼                           ▼
  ┌─────────────────────────┐   ┌─────────────────────────┐
  │      WORKER NODE 1      │   │      WORKER NODE 2      │
  │                         │   │                         │
  │  kubelet                │   │  kubelet                │
  │    └─▶ containerd (CRI) │   │    └─▶ containerd (CRI) │
  │          └─▶ [Pod]      │   │          └─▶ [Pod]      │
  │               [Pod]     │   │               [Pod]     │
  │  kube-proxy             │   │  kube-proxy             │
  │    └─▶ iptables rules   │   │    └─▶ iptables rules   │
  │  CNI plugin             │   │  CNI plugin             │
  │    └─▶ Pod network      │   │    └─▶ Pod network      │
  └─────────────────────────┘   └─────────────────────────┘
```

**CNI plugin:**
- kubeadm clusters → **Calico** (VXLAN overlay, `192.168.0.0/16` pod CIDR)
- EKS clusters → **aws-vpc-cni** (native VPC IPs assigned directly to pods)

---

## The 10-Step Flow: `kubectl apply` to Running Pod

```
  1. kubectl apply -f deployment.yaml
           │
           ▼
  2. kube-apiserver — TLS handshake, RBAC check, schema validation
           │
           ▼
  3. etcd — Deployment object written (status: desired=3, ready=0)
           │
           ▼
  4. Deployment Controller watches etcd — detects mismatch
           │
           ▼
  5. Deployment Controller creates ReplicaSet object
           │
           ▼
  6. ReplicaSet Controller creates 3 Pod objects (status: Pending, nodeName: "")
           │
           ▼
  7. kube-scheduler watches for Pending pods — scores nodes, assigns nodeName
           │
           ▼
  8. kubelet on assigned node detects Pod via watch loop
           │
           ▼
  9. kubelet → containerd: pull image, create container, start container
           │
           ▼
  10. CNI assigns Pod IP, kube-proxy updates iptables — Pod status: Running
```

Each step is expanded in detail in the sections below.

---

## Part 1 — Control Plane Components

### 1.1 — kube-apiserver

**What it is:** The single entry point for all cluster operations. Every component — kubectl, scheduler, controller manager, kubelet — communicates exclusively through the API server. Nothing talks directly to etcd except the API server.

**Port:** `6443` (HTTPS/TLS only)

```
  kubectl             CI/CD pipeline         kubelet (node)
      │                     │                     │
      └────────────┬─────────┘                    │
                   │                              │
                   ▼                              │
           ┌──────────────┐◀─────────────────────┘
           │ kube-apiserver│
           │              │
           │ 1. AuthN      │  ← Who are you? (TLS client cert, token, OIDC)
           │ 2. AuthZ      │  ← Are you allowed? (RBAC rules)
           │ 3. Admission  │  ← Is this valid? (webhooks, schema)
           │ 4. Persist    │  ← Write to etcd
           └──────┬───────┘
                  │
                  ▼
               etcd
```

**Why only the API server talks to etcd:**
Every other component talking to etcd directly would mean 10+ things all writing to the same database without coordination. The API server is the serialisation point — it ensures writes are consistent and watched by the right components.

**In this repo:**
- kubeadm lab: `sudo kubeadm init` generates the API server certificate and starts it as a static Pod at `/etc/kubernetes/manifests/kube-apiserver.yaml`
- EKS: AWS hosts and manages the API server — you never SSH into the control plane

**Verify it is responding:**
```bash
kubectl cluster-info
# Output: Kubernetes control plane is running at https://<ip>:6443

# Watch raw API calls (v=6 is verbose, v=8 shows full request/response bodies)
kubectl get pods -v=6
```

---

### 1.2 — etcd

**What it is:** A distributed, consistent key-value store. It is the database of Kubernetes — the single source of truth for every object in the cluster (Deployments, Pods, Services, ConfigMaps, Secrets, node registrations).

**Port:** `2379` (client), `2380` (peer/cluster)

```
  What lives in etcd:
  ┌──────────────────────────────────────────────────────┐
  │  /registry/deployments/default/nginx-deployment      │
  │  /registry/pods/default/nginx-deployment-7d9b-abc12  │
  │  /registry/services/default/nginx-clusterip-svc      │
  │  /registry/configmaps/default/static-site-html       │
  │  /registry/nodes/ip-10-0-1-45                        │
  │  /registry/secrets/default/my-secret                 │
  └──────────────────────────────────────────────────────┘
```

**How the watch mechanism works:**
All controllers and kubelets use a "watch" API call — a long-lived HTTP/2 stream. When you write a new Pod to etcd, the API server pushes an event to every watcher instantly. This is how the scheduler knows a new Pod is Pending within milliseconds — not by polling.

```
  etcd state change
       │
       ▼
  API server sends watch event
       │
       ├──▶ kube-scheduler  (new unscheduled Pod? assign a node)
       ├──▶ kubelet          (a Pod was assigned to my node? start it)
       └──▶ controller-mgr   (desired ≠ actual? reconcile)
```

**Why etcd uses the Raft consensus algorithm:**
In a production cluster, etcd runs as a 3-node or 5-node cluster. Raft ensures that a write is only acknowledged after a majority of nodes confirm it. This prevents "split-brain" — two nodes both believing they are the authoritative leader and writing conflicting state.

**In this repo:**
- kubeadm lab: single-node etcd (no HA). Losing the master loses the cluster
- EKS: AWS runs a multi-node etcd cluster across AZs — invisible to you

**Inspect etcd content (kubeadm):**
```bash
# Etcd runs as a static Pod on the master node
kubectl get pods -n kube-system | grep etcd

# Read a key directly (run on master node)
sudo ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/deployments/default/nginx-deployment --print-value-only

# Check cluster health
sudo ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

---

### 1.3 — kube-scheduler

**What it is:** Watches for Pods with no `nodeName` assigned and picks the best node to run them on.

**What it does NOT do:** It does not start the Pod. It only writes the chosen node name into the Pod spec. The kubelet on that node then picks it up and starts it.

```
  Pod created (nodeName: "")
          │
          ▼
  ┌──────────────────────────────────────┐
  │          kube-scheduler              │
  │                                      │
  │  Phase 1: FILTERING                  │
  │  Eliminate nodes that cannot run     │
  │  this Pod:                           │
  │  ✗ Not enough CPU/memory            │
  │  ✗ Node has incompatible taint       │
  │  ✗ Node does not match nodeSelector  │
  │                                      │
  │  Phase 2: SCORING                    │
  │  Rank remaining nodes (0–100):       │
  │  + More free resources = higher      │
  │  + Pod's preferred affinity matched  │
  │  + Anti-affinity respected           │
  │                                      │
  │  Phase 3: BINDING                    │
  │  Write nodeName to Pod spec in etcd  │
  └──────────────────────────────────────┘
          │
          ▼
  Pod (nodeName: "ip-10-0-1-45")
  kubelet on that node starts it
```

**Scheduling constraints you can set in YAML:**

| Constraint | Effect |
|---|---|
| `resources.requests` | Scheduler only places Pod on nodes with enough free resources |
| `nodeSelector` | Pin Pod to nodes with a specific label (e.g. `disk: ssd`) |
| `affinity.nodeAffinity` | Preferred or required node placement rules |
| `affinity.podAntiAffinity` | Spread replicas across different nodes or AZs |
| `tolerations` | Allow Pod to run on tainted nodes (e.g. GPU nodes) |

**In this repo:**
The `manifests/03-deployment/deployment.yaml` uses `resources.requests` — this directly affects which nodes the scheduler will consider. A node without enough free CPU/memory is filtered out.

---

### 1.4 — kube-controller-manager

**What it is:** A single binary that runs many independent control loops ("controllers"). Each controller manages one resource type using the same principle: watch desired state, compare to actual state, take action to close the gap.

```
  Desired state (in etcd)
         │
         │ "3 replicas specified"
  ┌──────▼──────────────────────┐
  │    ReplicaSet Controller    │
  │                             │
  │  Actual: 2 pods running     │
  │  Desired: 3 pods            │
  │  Gap: 1                     │
  │  Action: create 1 new Pod   │
  └─────────────────────────────┘
         │
         ▼
  New Pod object written to etcd
  → scheduler assigns node
  → kubelet starts container
```

**Key controllers and what they manage:**

| Controller | Watches | Action when gap detected |
|---|---|---|
| **Deployment** | Deployment objects | Creates/updates the ReplicaSet |
| **ReplicaSet** | ReplicaSet objects | Creates/deletes Pods to match `replicas` |
| **Node** | Node heartbeats | Marks node NotReady after 40s of silence; evicts pods after 5min |
| **Endpoint** | Services + Pods | Updates the Endpoints object (which Pod IPs are behind a Service) |
| **Namespace** | Namespace deletion | Cleans up all resources inside a deleted namespace |
| **Job / CronJob** | Job specs | Creates Pods for batch workloads |

**The self-healing you see in the ReplicaSet lab** (`manifests/02-replicaset/`) is the ReplicaSet controller at work. Delete a Pod → controller detects `actual(2) < desired(3)` → creates a replacement within seconds.

---

### 1.5 — cloud-controller-manager (EKS only)

**What it is:** The bridge between Kubernetes and AWS APIs. It runs on the EKS control plane and watches for cloud-specific resource requests.

```
  kubectl apply -f service-loadbalancer.yaml
          │
          ▼
  Service (type: LoadBalancer) created in etcd
          │
          ▼
  cloud-controller-manager detects it
          │
          ▼
  Calls AWS API: CreateLoadBalancer (NLB)
          │
          ▼
  NLB DNS name written back to Service.status.loadBalancer.ingress
          │
          ▼
  kubectl get svc → EXTERNAL-IP shows DNS name (~90 seconds)
```

**In this repo:** `manifests/06-static-site/service-loadbalancer.yaml` and `manifests/04-service/service-loadbalancer.yaml` both trigger this flow. The annotation `service.beta.kubernetes.io/aws-load-balancer-type: "nlb"` tells the cloud controller to request an NLB instead of a Classic LB.

**Why it does not work on kubeadm:** No cloud-controller-manager runs on bare EC2. The Service is created in etcd but no controller calls the AWS API, so `EXTERNAL-IP` stays `<pending>` indefinitely.

---

## Part 2 — Worker Node Components

### 2.1 — kubelet

**What it is:** The primary node agent. Runs on every worker node (and on the master node in kubeadm clusters). It is the component that actually makes containers run.

```
  ┌─────────────────────────────────────────────────────┐
  │                    kubelet                          │
  │                                                     │
  │  1. Registers node with API server on startup       │
  │  2. Watches API server for Pods assigned to it      │
  │  3. Calls container runtime (containerd) via CRI    │
  │  4. Manages Pod lifecycle (start / stop / restart)  │
  │  5. Runs liveness and readiness health probes       │
  │  6. Reports Pod and node status back to API server  │
  │  7. Mounts volumes (ConfigMaps, Secrets, PVCs)      │
  └─────────────────────────────────────────────────────┘
         │                          │
         ▼ CRI (gRPC)              ▼ status updates
    containerd               kube-apiserver
```

**How the kubelet starts a Pod (detailed):**

```
  kubelet receives Pod spec (via watch event)
         │
         ├─▶ 1. Pull image (calls containerd → pulls from registry)
         ├─▶ 2. Create container (calls containerd CRI)
         ├─▶ 3. Call CNI plugin (assigns Pod IP, creates veth interface)
         ├─▶ 4. Mount volumes (ConfigMap, Secret, PVC)
         ├─▶ 5. Set environment variables
         ├─▶ 6. Start container
         └─▶ 7. Begin health probes (liveness, readiness, startup)
```

**The ConfigMap volume mount** used in `manifests/06-static-site/deployment.yaml` is handled entirely by the kubelet — it reads the ConfigMap from etcd, creates a tmpfs-backed file on the node, and mounts it into the container at `/usr/share/nginx/html/index.html`.

**In this repo:**
- `master-init.sh` installs and starts kubelet as a systemd service
- Configured to use `systemd` cgroup driver (must match containerd — a mismatch causes the node to not join)

```bash
# Verify kubelet is running on any node
sudo systemctl status kubelet

# View kubelet logs (most useful for debugging pod startup failures)
journalctl -u kubelet -f

# See what static pods kubelet is managing on the master
sudo ls /etc/kubernetes/manifests/
# kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml  etcd.yaml
```

> **Static Pods:** The control plane components (apiserver, etcd, scheduler, controller-manager) themselves run as Pods managed directly by the kubelet from YAML files in `/etc/kubernetes/manifests/` — not through the API server. The kubelet reads these files on disk and keeps them running. This is how the cluster bootstraps: the kubelet starts the API server, and only then can everything else use the API.

---

### 2.2 — Container Runtime (containerd)

**What it is:** The software that actually runs containers on the node. Kubernetes talks to it via the **CRI (Container Runtime Interface)** — a gRPC API that every compliant runtime must implement.

```
  kubelet
     │
     │ CRI (gRPC)
     ▼
  containerd
     │
     ├─▶ containerd-shim-runc-v2
     │         │
     │         ▼
     │      runc (OCI runtime — creates the actual Linux container)
     │         │
     │         ▼
     │      [namespace, cgroups, seccomp, Linux namespaces]
     │
     └─▶ Image management (pull, store, layer cache)
```

**Why not Docker?**
Docker was the original runtime, but in Kubernetes 1.24 the "dockershim" (Docker compatibility layer) was removed. `containerd` was already inside Docker — Kubernetes now uses it directly, skipping the Docker layer entirely. The result: faster start times, less memory overhead, and a cleaner CRI-compliant interface.

**In this repo:**
`master-init.sh` installs containerd from the Docker repository (which provides newer versions than `apt`), generates `/etc/containerd/config.toml`, and sets `SystemdCgroup = true`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

This cgroup driver setting must match kubelet's `cgroupDriver: systemd` — a mismatch is the most common cause of `node NotReady` on fresh installs.

```bash
# Verify containerd is running
sudo systemctl status containerd

# List all containers on the node (equivalent of `docker ps`)
sudo crictl ps

# List all containers including failed/exited
sudo crictl ps -a

# Pull an image manually (bypasses kubelet)
sudo crictl pull nginx:alpine

# Inspect a running container
sudo crictl inspect <container-id>
```

---

### 2.3 — kube-proxy

**What it is:** Runs on every node and maintains network rules (iptables or IPVS) that implement Kubernetes Services. It is what makes `ClusterIP`, `NodePort`, and `LoadBalancer` Services actually route traffic to the right Pods.

```
  Client sends traffic to Service ClusterIP (e.g. 10.100.200.228:80)
          │
          ▼
  kernel intercepts packet (iptables PREROUTING chain)
          │
          ▼
  kube-proxy-written iptables rule: DNAT
  10.100.200.228:80  →  randomly select one of:
     192.168.1.5:80   (Pod 1)
     192.168.2.8:80   (Pod 2)
          │
          ▼
  Packet delivered to selected Pod
```

**Service type → kube-proxy rule:**

| Service type | What kube-proxy writes |
|---|---|
| `ClusterIP` | iptables DNAT rule: ClusterIP → one of the Pod IPs |
| `NodePort` | iptables rule: `<any-node-ip>:<nodePort>` → ClusterIP → Pod |
| `LoadBalancer` | Same as NodePort (the NLB sends traffic to the NodePort on each node) |

**Critical understanding about NodePort access in EKS:**
When you applied `manifests/06-static-site/service-nodeport.yaml`, kube-proxy wrote the port 30090 rule on every worker node. `curl http://<node-ip>:30090` hits any node in the cluster — not just the node where the Pod is running. kube-proxy forwards it across the cluster via the ClusterIP rule.

```bash
# See the actual iptables rules kube-proxy has written
sudo iptables -t nat -L KUBE-SERVICES -n | grep static-site

# View kube-proxy logs
kubectl logs -n kube-system -l k8s-app=kube-proxy
```

---

### 2.4 — CNI Plugin (Network)

**What it is:** The Container Network Interface plugin gives every Pod a routable IP address and connects it to the cluster network. Different clusters use different CNI plugins — but all pods see the same flat network regardless.

**Kubernetes networking contract (fundamental rules):**
1. Every Pod gets its own unique IP address
2. All Pods can reach all other Pods without NAT
3. Nodes can reach all Pods without NAT
4. A Pod's IP is the same from inside and outside the Pod

#### Calico (lab-01-kubeadm)

```
  Worker Node 1 (10.0.1.10)                Worker Node 2 (10.0.2.15)
  ┌─────────────────────────┐               ┌─────────────────────────┐
  │  Pod A  192.168.1.2     │               │  Pod B  192.168.2.3     │
  │   │                     │               │   │                     │
  │  veth0                  │               │  veth0                  │
  │   │                     │               │   │                     │
  │  cali1234 (host veth)   │               │  cali5678 (host veth)   │
  │   │                     │               │   │                     │
  │  node routing table     │               │  node routing table     │
  └──────────┬──────────────┘               └──────────┬──────────────┘
             │  VXLAN tunnel (UDP 4789)                 │
             └─────────────────────────────────────────┘
```

Calico wraps Pod-to-Pod traffic in VXLAN (UDP 4789) when nodes are in different subnets. Within the same subnet it can use direct BGP routing — more efficient but requires Layer 2 adjacency.

#### aws-vpc-cni (lab-02-eks)

```
  Worker Node (ENI: eth0 = 192.168.1.5)
  ┌──────────────────────────────────────┐
  │  Pod A  192.168.1.8    ← real VPC IP │
  │  Pod B  192.168.1.9    ← real VPC IP │
  │  Pod C  192.168.1.10   ← real VPC IP │
  └──────────────────────────────────────┘
```

On EKS, the aws-vpc-cni plugin requests **secondary IP addresses** from AWS for each ENI on the node. Pods get real VPC IPs — no overlay, no VXLAN, no tunneling. Pod-to-Pod traffic across nodes travels the normal AWS VPC routing fabric. This is faster and simpler — but limits the number of Pods per node to the ENI secondary IP limit of the instance type.

```bash
# See CNI plugin running (kubeadm)
kubectl get pods -n kube-system | grep calico

# See CNI plugin running (EKS)
kubectl get pods -n kube-system | grep aws-node

# Inspect Pod IPs (confirm they're in the pod CIDR)
kubectl get pods -o wide
```

---

## Part 3 — Networking Objects

### 3.1 — Service

A Service is a stable virtual IP (`ClusterIP`) and DNS name in front of a dynamic set of Pods. It decouples consumers from the Pod lifecycle — Pods are replaced constantly; the Service IP never changes.

```
  Service: nginx-clusterip-svc
  ClusterIP: 10.100.50.30
  Selector: app=nginx
  Port: 80

  DNS name (in-cluster): nginx-clusterip-svc.default.svc.cluster.local

  Traffic flow:
  Pod A → 10.100.50.30:80
        → iptables (kube-proxy)
        → DNAT to one of:
              192.168.1.5:80  (nginx pod 1)
              192.168.2.3:80  (nginx pod 2)
              192.168.1.9:80  (nginx pod 3)
```

The **Endpoints** object (managed by the Endpoint Controller) is the live list of Pod IPs behind a Service. When a Pod dies, its IP is removed from Endpoints within seconds. New traffic stops going to it immediately.

```bash
# See which Pods are behind a Service right now
kubectl get endpoints static-site-nodeport

# Watch endpoints update in real time as Pods are added/removed
kubectl get endpoints static-site-nodeport -w
```

### 3.2 — Service Types Compared

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  ClusterIP (default)                                             │
  │  In-cluster only. No external access.                           │
  │  Use for: databases, internal APIs.                             │
  │                                                                  │
  │  [Pod] → ClusterIP:80 → iptables → [backend Pod]               │
  └──────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────┐
  │  NodePort                                                        │
  │  Opens a port (30000-32767) on EVERY node.                      │
  │  Use for: dev/test, kubeadm clusters.                           │
  │                                                                  │
  │  External → node-ip:30090 → ClusterIP:80 → [backend Pod]       │
  └──────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────┐
  │  LoadBalancer (EKS only in this repo)                           │
  │  Provisions a real AWS NLB.                                     │
  │  Use for: production public endpoints.                          │
  │                                                                  │
  │  Internet → NLB DNS → node:30090 → ClusterIP:80 → [backend Pod]│
  └──────────────────────────────────────────────────────────────────┘
```

---

## Part 4 — Configuration Objects

### 4.1 — ConfigMap

Stores non-sensitive configuration data as key-value pairs. Decouples configuration from container images — you can update configuration without rebuilding or retagging an image.

```
  ConfigMap: static-site-html
  key: index.html
  value: <full HTML page content>
         │
         ▼
  Deployment spec:
  volumes:
    - name: html
      configMap:
        name: static-site-html

  volumeMounts:
    - mountPath: /usr/share/nginx/html/index.html
      subPath: index.html
         │
         ▼
  kubelet reads ConfigMap from etcd
  → creates tmpfs file on node
  → mounts file into container at the specified path
  → nginx serves it
```

**`subPath`** is critical here — without it, mounting a ConfigMap to a directory replaces the entire directory. With `subPath: index.html`, only that single file is mounted, leaving the rest of `/usr/share/nginx/html/` intact.

**Updating the page without a redeploy:**
```bash
kubectl edit configmap static-site-html          # edit the HTML
kubectl rollout restart deployment/static-site   # pods remount the updated file
```

### 4.2 — Secret

Functionally identical to ConfigMap, but the values are base64-encoded and access-controlled separately via RBAC. Secrets are intended for passwords, tokens, TLS certificates.

> Base64 encoding is **not encryption**. Secrets at rest in etcd are unencrypted by default. For production, enable etcd encryption or use an external secrets manager (AWS Secrets Manager via External Secrets Operator, or HashiCorp Vault).

---

## Part 5 — Resource Management

### 5.1 — Requests and Limits

Every manifest in this repo specifies `resources.requests` and `resources.limits`. Here is exactly how each affects the system:

```
  resources:
    requests:
      cpu: 100m       ← "I need at least 0.1 vCPU to start"
      memory: 64Mi    ← "I need at least 64MB of RAM"
    limits:
      cpu: 200m       ← "Never give me more than 0.2 vCPU"
      memory: 128Mi   ← "Kill me if I exceed 128MB"
```

| Field | Affects | Consequence of breach |
|---|---|---|
| `requests.cpu` | Scheduler (node filtering) | Pod won't be placed if no node has enough free CPU |
| `requests.memory` | Scheduler (node filtering) | Pod won't be placed if no node has enough free memory |
| `limits.cpu` | cgroups (kernel) | Container is CPU-throttled (slows down, not killed) |
| `limits.memory` | cgroups (kernel) | Container is OOMKilled immediately |

**Quality of Service classes** (Kubernetes assigns these automatically):

| Class | Condition | Eviction priority |
|---|---|---|
| `Guaranteed` | requests == limits for all containers | Last to be evicted |
| `Burstable` | requests set, limits > requests | Middle priority |
| `BestEffort` | no requests or limits set | First to be evicted under pressure |

All manifests in this repo are `Burstable` (requests < limits). Never run `BestEffort` in a shared cluster.

---

## Part 6 — Full Component Interaction Reference

```
COMPONENT             TALKS TO               PROTOCOL      PORT
─────────────────────────────────────────────────────────────────────
kubectl               kube-apiserver         HTTPS/TLS     6443
kube-apiserver        etcd                   gRPC/TLS      2379
kube-scheduler        kube-apiserver         HTTPS watch   6443
kube-controller-mgr   kube-apiserver         HTTPS watch   6443
kubelet               kube-apiserver         HTTPS watch   6443
kubelet               containerd             gRPC (CRI)    unix socket
containerd            container registry     HTTPS         443
kube-proxy            kube-apiserver         HTTPS watch   6443
kube-proxy            iptables/netfilter     kernel call   —
CNI plugin            kube-apiserver         HTTPS         6443
CNI plugin (Calico)   other nodes (VXLAN)    UDP           4789
CNI plugin (Calico)   other nodes (BGP)      TCP           179
etcd peers            each other             gRPC/TLS      2380
```

---

## Summary: Who Does What

| Component | One-line role |
|---|---|
| **kubectl** | CLI client — translates commands into API server calls |
| **kube-apiserver** | The only door into the cluster — authenticates, authorises, persists |
| **etcd** | The cluster's memory — stores every object's desired and observed state |
| **kube-scheduler** | The placement engine — assigns Pods to nodes |
| **kube-controller-manager** | The reconciliation engine — closes gaps between desired and actual state |
| **cloud-controller-manager** | AWS integration — provisions NLBs, EBS volumes (EKS only) |
| **kubelet** | The node agent — makes containers run, reports health |
| **containerd** | The container runtime — pulls images, creates Linux containers |
| **kube-proxy** | The traffic router — writes iptables rules for Services |
| **CNI plugin** | The network plumber — gives Pods IPs and connects them |

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
