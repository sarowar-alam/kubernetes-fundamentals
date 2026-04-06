# Session 2 — Kubernetes Architecture

---

## Overview

Every Kubernetes cluster has two types of machines:

```
┌─────────────────────────────────────────────────────────────┐
│                     KUBERNETES CLUSTER                      │
│                                                             │
│   ┌──────────────────────┐    ┌──────────────────────────┐  │
│   │    MASTER NODE        │    │      WORKER NODE 1       │  │
│   │  (Control Plane)     │    │   (Runs your apps)        │  │
│   │                      │────│                           │  │
│   │  API Server          │    │  kubelet                  │  │
│   │  Scheduler           │    │  kube-proxy               │  │
│   │  Controller Manager  │    │  Container Runtime        │  │
│   │  etcd                │    │  [Pod] [Pod] [Pod]        │  │
│   └──────────────────────┘    └──────────────────────────┘  │
│                                ┌──────────────────────────┐  │
│                                │      WORKER NODE 2       │  │
│                                │   (Runs your apps)        │  │
│                                │                           │  │
│                                │  kubelet                  │  │
│                                │  kube-proxy               │  │
│                                │  Container Runtime        │  │
│                                │  [Pod] [Pod]              │  │
│                                └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Master Node** = Brain of the cluster. Makes decisions. Manages state.  
**Worker Nodes** = Muscle. Actually runs your containers.

---

## Part 1: Control Plane (Master Node)

### Analogy
Think of the Control Plane like an **Air Traffic Control Tower**:
- It knows where every plane (pod) is
- It decides where new planes land (which node)
- It watches for problems and reacts immediately
- Pilots (your apps) just fly — they don't manage the tower

---

### 1.1 API Server (`kube-apiserver`)

**What it is:**  
The front door of the entire cluster. Every operation goes through the API server — whether it's `kubectl`, a CI/CD pipeline, or internal components talking to each other.

**Theory Explanation:**
- Exposes the Kubernetes REST API on port `6443`
- Authenticates and authorizes every request
- Validates YAML manifests before accepting them
- Writes desired state to etcd
- Is the ONLY component that talks to etcd

```
   You (kubectl)  →  API Server  →  etcd (store state)
   CI/CD Pipeline →  API Server  →  etcd
   kubelet        →  API Server  →  etcd
```

**Teaching marker:** [THEORY — explain verbally, draw the request flow on whiteboard]

**Key facts to remember:**
- If the API server is down, `kubectl` stops working
- The API server is stateless — all state is in etcd
- In production, you run multiple API server replicas behind a load balancer

---

### 1.2 Scheduler (`kube-scheduler`)

**What it is:**  
Decides *where* (which worker node) a new pod should run.

**Theory Explanation:**
The Scheduler watches for pods that have been created but not yet assigned to a node. It then evaluates all worker nodes and picks the best one.

**How it decides (simplified):**
```
New Pod needs: 2 CPU, 1GB RAM

Worker Node 1: 1 CPU available     → NOT enough, skip
Worker Node 2: 3 CPU available     → OK
Worker Node 3: 4 CPU available     → OK

Scheduler checks "affinity", "taints", "topology" rules...
Result: assign to Worker Node 2
```

**Teaching marker:** [THEORY — explain the factors; no direct demo possible for internals]

**Factors the scheduler considers:**
- Available CPU and memory on each node
- Node selectors and affinity rules (you can pin pods to specific nodes)
- Taints and tolerations (mark nodes as "no general workloads")
- Pod anti-affinity (don't put two replicas on the same node)

---

### 1.3 Controller Manager (`kube-controller-manager`)

**What it is:**  
A collection of control loops that continuously watch the cluster state and make corrections to match desired state.

**Analogy:**  
Think of a thermostat. You set the temperature to 22°C (desired state). The thermostat continuously checks the actual temperature — if it drops to 20°C, it turns on the heater. The Controller Manager does the same thing for your cluster.

```
Desired State  →  Controller Manager watches
Actual State   →  Controller Manager compares

If desired ≠ actual → Controller takes action
```

**Built-in controllers and what they manage:**

| Controller | Responsibility |
|---|---|
| **Node Controller** | Detects when nodes go down; marks pods as failed |
| **Replication Controller** | Ensures the right number of pod replicas exist |
| **Endpoints Controller** | Updates the list of IPs behind a Service |
| **Service Account Controller** | Creates service accounts for new namespaces |
| **Deployment Controller** | Manages rolling updates via ReplicaSets |

**Teaching marker:** [THEORY — explain the thermostat analogy; demonstrate self-healing with ReplicaSet later]

**Demo-able later:** When you delete a pod in a ReplicaSet, the Replication Controller (inside the Controller Manager) immediately creates a new one. Students can observe this.

---

### 1.4 etcd

**What it is:**  
The cluster's database. Stores the entire state of the cluster — every object, every config, every secret.

**Analogy:**  
etcd is like a **Git repository for your cluster state**. Every time you create a deployment or change a config, it gets written to etcd. If the cluster crashes and restarts, it reads from etcd to restore everything.

**Technical details:**
- Distributed, consistent key-value store
- Uses the Raft consensus algorithm for reliability
- Runs on port `2379` (client) and `2380` (peer-to-peer)
- Only the API server talks to etcd directly

**Why it matters:**
```
If etcd is corrupted → entire cluster state is lost
That's why in production: backup etcd daily, or use EKS (AWS manages it for you)
```

**Teaching marker:** [THEORY — no direct demo; draw data flow diagram]

**Critical security note:** etcd stores Kubernetes Secrets (API keys, database passwords). It must be encrypted at rest and never exposed to the internet.

---

## Part 2: Worker Node Components

### Analogy
If the Control Plane is the Air Traffic Control Tower, Worker Nodes are the **runways and aircraft hangars** — the actual physical infrastructure where planes (pods) land and operate.

---

### 2.1 kubelet

**What it is:**  
An agent that runs on every worker node. It receives instructions from the API server and ensures that the right containers are running on the node.

**How it works:**
```
API Server:  "Run pod 'web-app' with image nginx:1.25 on this node"
     ↓
kubelet:     Calls the container runtime: "Please start this container"
     ↓
Container Runtime starts the container
     ↓
kubelet:     Reports back to API server: "Pod is Running"
             Keeps checking: if pod dies, reports it
```

**Teaching marker:** [THEORY + DEMO — after kubeadm setup, `systemctl status kubelet` and show logs on a worker node]

**Key facts:**
- kubelet does NOT manage containers created outside Kubernetes (e.g., manually with `docker run`)
- Reports node resource usage (CPU, memory) to API server
- Health-checks containers using liveness/readiness probes

---

### 2.2 kube-proxy

**What it is:**  
A network component that runs on every node. It maintains network rules so that pods can communicate with each other and with Services.

**How it works:**
```
You create a Service (ClusterIP 10.96.0.1, port 80)
         ↓
kube-proxy sees this Service in etcd (via API server)
         ↓
kube-proxy writes iptables rules on the node:
  "Traffic to 10.96.0.1:80 → forward to pod IP 192.168.1.5:8080"
         ↓
When a request arrives at 10.96.0.1:80, the kernel routes it correctly
```

**Teaching marker:** [THEORY — explain the role; can show `iptables -L -n -t nat` on a node to see actual rules]

**Key facts:**
- Implements Kubernetes Services networking
- Supports IPVS mode (more performant than iptables at scale)
- One kube-proxy per node — it configures that node's network rules

---

### 2.3 Container Runtime

**What it is:**  
The software that actually *runs* containers. Kubernetes is container-runtime-agnostic — it uses the Container Runtime Interface (CRI) to talk to whatever runtime is installed.

**Supported runtimes:**

| Runtime | Notes |
|---|---|
| **containerd** | Default, used by most clusters including EKS |
| **CRI-O** | Lightweight, used by OpenShift |
| Docker (via dockershim) | Removed in Kubernetes 1.24 |

**Why we use `containerd` (not Docker) in our labs:**
- Docker was removed from K8s in v1.24
- `containerd` is what Docker itself uses under the hood
- Lighter, faster, supports CRI natively

**Teaching marker:** [THEORY + DEMO — `crictl ps` on worker node to list running containers; show `containerd` service status]

---

## Part 3: Theory vs Practical Summary

| Component | Explain Theoretically | Demo / Observe Practically |
|---|---|---|
| API Server | Request flow, port 6443, auth | `kubectl get pods -v=8` (watch API calls) |
| Scheduler | Scheduling algorithm, node selection | Observe pod placement on nodes |
| Controller Manager | Thermostat analogy, control loops | Delete a pod → watch it recreate |
| etcd | State store, Raft, backup importance | `kubectl get secrets` → data lives in etcd |
| kubelet | Agent, container lifecycle | `systemctl status kubelet`, `journalctl -u kubelet` |
| kube-proxy | iptables rules, Service implementation | `iptables -L -n -t nat \| grep KUBE` |
| Container Runtime | CRI, containerd | `crictl ps`, `crictl images` |

---

## Part 4: How a Pod Gets Scheduled (End-to-End Flow)

This is one of the most important things to understand. Walk through this step by step.

```
Step 1: You run:
        kubectl apply -f pod.yaml

Step 2: kubectl sends HTTP request to:
        API Server (port 6443)

Step 3: API Server:
        - Authenticates you
        - Validates the YAML
        - Writes "Pod desired, unscheduled" to etcd

Step 4: Scheduler:
        - Watches etcd (via API server) for unscheduled pods
        - Finds this new pod
        - Evaluates all worker nodes
        - Picks Worker Node 1
        - Writes "assign this pod to Worker Node 1" to etcd

Step 5: kubelet on Worker Node 1:
        - Watches etcd (via API server) for pods assigned to it
        - Sees this new assignment
        - Instructs containerd to pull the image and start the container
        - Container starts

Step 6: kubelet reports back:
        - Pod status → "Running"
        - API Server writes this to etcd

Step 7: You run kubectl get pods:
        - API Server reads from etcd
        - Shows you: pod is Running on Worker Node 1
```

**Teaching marker:** [THEORY + DRAW on whiteboard — trace this flow slowly, it's the "aha" moment for students]

---

## Part 5: Common Mistakes & Misconceptions

1. **"The master node runs my app"** — No. The master node runs control plane components only. Your pods run on worker nodes. (In small dev clusters like minikube, master and worker are combined — but not in production.)

2. **"etcd is just a database I can query directly"** — No. Never query etcd directly. Always use `kubectl` which goes through the API server.

3. **"If the master node crashes, my app stops"** — No. Your pods on worker nodes keep running. But you can't manage them (no `kubectl` commands work). That's why production clusters use 3 master nodes.

4. **"kube-proxy is a proxy like nginx"** — Not quite. It creates iptables rules at the kernel level. It's transparent to your application.

5. **"Docker is required to use Kubernetes"** — No. Kubernetes uses `containerd` directly. Docker is not needed.
