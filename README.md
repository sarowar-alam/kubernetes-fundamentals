# kubernetes-fundamentals

A hands-on Kubernetes learning repository covering two real-world cluster patterns — a self-hosted cluster built with **kubeadm on AWS EC2**, and a managed cluster on **Amazon EKS** — alongside a progressive set of Kubernetes manifests from basic Pods to a fully deployed static web application.

> **Course context:** Batch-09 · Module-11 · DevOps Engineering Track

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Technology Stack](#technology-stack)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Lab 01 — kubeadm Self-Hosted Cluster](#lab-01--kubeadm-self-hosted-cluster)
- [Lab 02 — Amazon EKS Managed Cluster](#lab-02--amazon-eks-managed-cluster)
- [Manifests — Progressive Resource Examples](#manifests--progressive-resource-examples)
- [Switching Between Clusters](#switching-between-clusters)
- [Making Changes Safely](#making-changes-safely)
- [Reliability and Operational Considerations](#reliability-and-operational-considerations)
- [Teardown](#teardown)
- [Reference](#reference)

---

## Architecture Overview

Two independent labs demonstrate the same Kubernetes concepts from opposite ends of the operational spectrum.

### Lab 01 — kubeadm (Self-Hosted)

```
AWS ap-south-1 — devops-vpc (10.0.0.0/16)
┌─────────────────────────────────────────────────────┐
│  Public Subnet (ap-south-1a)                        │
│  ┌──────────────────────────────────────────────┐   │
│  │  Master Node (t3.medium, Ubuntu 22.04)       │   │
│  │  • kube-apiserver   :6443                    │   │
│  │  • etcd             :2379                    │   │
│  │  • kube-scheduler                            │   │
│  │  • kube-controller-manager                   │   │
│  │  • Calico CNI (podCIDR: 192.168.0.0/16)      │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  Private Subnets (1b / 1c)                          │
│  ┌──────────────────────┐  ┌──────────────────────┐ │
│  │  Worker Node 1       │  │  Worker Node 2       │ │
│  │  t3.medium           │  │  t3.medium           │ │
│  │  kubelet + containerd│  │  kubelet + containerd│ │
│  └──────────────────────┘  └──────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

Every component is manually provisioned — giving complete visibility into how Kubernetes works internally.

### Lab 02 — Amazon EKS (Managed)

```
AWS ap-south-1 — eksctl-managed VPC (192.168.0.0/16)
┌─────────────────────────────────────────────────────────────┐
│  AWS-Managed Control Plane (invisible, SLA-backed)          │
│  kube-apiserver · etcd · kube-scheduler · kube-cm           │
├─────────────────────────────────────────────────────────────│
│  Public Subnets (1a · 1b · 1c) — IGW, NAT Gateway, NLBs     │
├─────────────────────────────────────────────────────────────│
│  Private Subnets (1a · 1b · 1c) — Worker Nodes              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Managed Node Group (t3.medium, AmazonLinux2023)    │    │
│  │  1–3 replicas · gp3 EBS · OIDC/IRSA enabled         │    │
│  └─────────────────────────────────────────────────────┘    │
│  AWS Addons: vpc-cni · coredns · kube-proxy · ebs-csi       │
└─────────────────────────────────────────────────────────────┘
```

AWS owns the control plane. You interact with it identically via `kubectl` — the same manifests run on both clusters.

### Design Decisions

| Decision | Rationale |
|---|---|
| **kubeadm lab** teaches every step | Full visibility into bootstrap phases, certificates, etcd, CNI install — things managed Kubernetes hides |
| **containerd** (not Docker) | Docker shim removed in K8s 1.24+. containerd is the direct CRI-compliant runtime used in production |
| **Calico CNI** | Production-grade; supports `NetworkPolicy` for pod-level firewall rules |
| **K8s 1.29** for kubeadm | LTS stream. `apt-mark hold` prevents accidental drift |
| **K8s 1.35 on EKS** | Latest stable release; AmazonLinux2023 required for 1.30+ |
| **OIDC + IRSA** on EKS | Pods get short-lived IAM credentials automatically — no static keys in Secrets |
| **Single NAT Gateway** | Cost-optimised for labs (~$0.06/hr). Switch to `HighlyAvailable` for production (one NAT per AZ) |
| **eksctl owns the VPC** | `eksctl delete cluster` removes all networking in one command — no orphaned resources |
| **Idempotent scripts** | All shell scripts check current state before acting — safe to re-run after partial failures |
| **ConfigMap for HTML** | Static site content decoupled from the container image — update page content without a rebuild or registry |

---

## Technology Stack

| Layer | Technology | Version |
|---|---|---|
| **Container runtime** | containerd | latest (from Docker repo) |
| **Cluster bootstrap** | kubeadm / kubelet | 1.29.0 |
| **Managed Kubernetes** | Amazon EKS | 1.35 |
| **EKS provisioning** | eksctl | 0.225.0+ |
| **CNI (kubeadm)** | Calico | v3.27.0 |
| **CNI (EKS)** | AWS VPC CNI | AWS-managed |
| **DNS** | CoreDNS | AWS-managed |
| **Storage** | AWS EBS (gp3) | AWS-managed |
| **Node OS (kubeadm)** | Ubuntu 22.04 LTS | ami-05d2d839d4f73aafb |
| **Node OS (EKS)** | Amazon Linux 2023 | AWS-managed |
| **Instance type** | AWS EC2 t3.medium | 2 vCPU / 4 GB RAM |
| **CLI tools** | kubectl, AWS CLI v2 | v1.35.3 / v2.34.24+ |
| **Region** | AWS ap-south-1 (Mumbai) | — |
| **Static site runtime** | nginx:alpine | latest |
| **Scripting** | Bash (POSIX-compatible) | — |

---

## Repository Layout

```
kubernetes-fundamentals/
│
├── README.md                        ← You are here
├── kubectl-cheatsheet.md            ← Day-to-day kubectl reference
├── .gitignore
│
├── docs/
│   ├── 01-introduction.md           ← Course introduction
│   └── 02-architecture.md           ← Deep-dive architecture notes
│
├── labs/
│   ├── lab-01-kubeadm/              ← Self-hosted K8s on EC2
│   │   ├── README.md                  ← Full step-by-step guide
│   │   ├── provision-ec2.sh           ← Launch EC2 instances
│   │   ├── master-init.sh             ← Bootstrap master node
│   │   ├── master-init-guide.md       ← Annotated walkthrough
│   │   ├── worker-join.sh             ← Join worker nodes
│   │   └── worker-join-guide.md       ← Annotated walkthrough
│   │
│   └── lab-02-eks/                  ← Amazon EKS managed cluster
│       ├── README.md                  ← Full step-by-step guide
│       ├── cluster-config.yaml        ← Declarative cluster definition
│       └── install-eksctl.sh          ← Install eksctl + kubectl + AWS CLI
│
└── manifests/                       ← Progressive Kubernetes examples
    ├── README.md                      ← Central apply/verify/cleanup guide
    ├── 01-pod/                        ← basic + multi-container pod
    ├── 02-replicaset/                 ← self-healing replica set
    ├── 03-deployment/                 ← rolling update + rollback
    ├── 04-service/                    ← ClusterIP / NodePort / LoadBalancer
    ├── 05-namespace/                  ← dev + staging isolation
    └── 06-static-site/                ← ConfigMap + Deployment + NodePort/NLB
```

---

## Prerequisites

### All labs

| Tool | Minimum version | Install |
|---|---|---|
| AWS CLI v2 | 2.x | [docs.aws.amazon.com](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| kubectl | 1.29+ | Included in `install-eksctl.sh` |
| SSH client | any | Pre-installed on Linux/macOS; Git Bash on Windows |
| Git | any | Pre-installed or [git-scm.com](https://git-scm.com) |

### AWS account requirements

An AWS account with the following configured:

```bash
# Create and verify the named profile used by all automation
aws configure --profile sarowar-ostad
#  AWS Access Key ID     : <your key>
#  AWS Secret Access Key : <your secret>
#  Default region        : ap-south-1
#  Default output format : json

# Verify authentication
aws sts get-caller-identity --profile sarowar-ostad
```

IAM permissions required (attach to the user or role):

| Permission set | Used by |
|---|---|
| AmazonEC2FullAccess | provision-ec2.sh, kubeadm lab |
| AmazonEKSClusterPolicy + EKSWorkerNodePolicy | EKS cluster |
| AmazonVPCFullAccess | Both labs |
| IAMFullAccess (or scoped EKS IAM) | eksctl IAM role creation |
| AWSCloudFormationFullAccess | eksctl stack management |
| AmazonSSMManagedInstanceCore | SSM instance profile on EC2 |

### For lab-01 (kubeadm) only

- EC2 key pair named **`sarowar-ostad-mumbai`** must exist in `ap-south-1` ([create one](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html))
- Existing VPC and subnets (the default `devops-vpc` is pre-configured in `provision-ec2.sh`)
- The instance security group must allow: TCP 22 (SSH), TCP 6443 (K8s API), TCP 2379–2380 (etcd), UDP 8472 (Calico VXLAN)

### For lab-02 (EKS) only

- eksctl installed (run `labs/lab-02-eks/install-eksctl.sh`)
- eksctl creates its own VPC; no pre-existing infrastructure needed

---

## Quick Start

### Clone the repository

```bash
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals
```

### Choose your path

| Goal | Start here |
|---|---|
| Learn how Kubernetes works internally | [Lab 01 — kubeadm](#lab-01--kubeadm-self-hosted-cluster) |
| Use a production-like managed cluster | [Lab 02 — EKS](#lab-02--amazon-eks-managed-cluster) |
| Practice workload deployments only (cluster already running) | [Manifests](#manifests--progressive-resource-examples) |

---

## Lab 01 — kubeadm Self-Hosted Cluster

Full guide: [labs/lab-01-kubeadm/README.md](labs/lab-01-kubeadm/README.md)

### Step 1 — Provision EC2 instances

```bash
cd labs/lab-01-kubeadm
bash provision-ec2.sh
```

This creates EC2 instances (1 public master + configurable private workers), tags them, and writes a `cluster-state.env` file with instance IDs and IPs.

Key overrides (no script editing required):

```bash
# Change instance type or count
INSTANCE_TYPE=t3.large PUBLIC_COUNT=1 PRIVATE_COUNT=2 bash provision-ec2.sh

# Use a different AWS profile or region
AWS_PROFILE=myprofile AWS_REGION=us-east-1 bash provision-ec2.sh
```

### Step 2 — Initialise the master node

SSH into the master node, then run:

```bash
# Option A — clone and run
sudo apt-get install -y git
git clone https://github.com/sarowar-alam/kubernetes-fundamentals.git
cd kubernetes-fundamentals/labs/lab-01-kubeadm
sudo ./master-init.sh

# Option B — one-liner (no git needed)
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/kubernetes-fundamentals/main/labs/lab-01-kubeadm/master-init.sh | sudo bash
```

`master-init.sh` handles everything in two phases:

**Phase 1 — System preparation:**
- apt update/upgrade
- Disable swap (required by kubelet)
- Load `overlay` and `br_netfilter` kernel modules
- Configure `net.bridge.bridge-nf-call-iptables` and `ip_forward`
- Install containerd from the Docker repository, configured with `systemd` cgroup driver
- Install kubeadm, kubelet, kubectl at v1.29.0, pinned with `apt-mark hold`

**Phase 2 — Cluster bootstrap:**
- `kubeadm init` with pod CIDR `192.168.0.0/16`
- Configure `~ubuntu/.kube/config`
- Install Calico CNI v3.27.0
- Print the `kubeadm join` command

### Step 3 — Join worker nodes

SSH into each worker node, then run:

```bash
# Interactive — script prompts for Master IP, Token, and Discovery Hash
sudo ./worker-join.sh

# Non-interactive — pass values via environment variables
sudo MASTER_IP=10.0.1.x \
     JOIN_TOKEN=abcdef.1234567890abcdef \
     JOIN_HASH=sha256:abc123... \
     ./worker-join.sh
```

Workers run the same Phase 1 system preparation, then execute `kubeadm join`.

### Step 4 — Verify

Run on the master node:

```bash
# All nodes must show Ready
kubectl get nodes

# All system pods must show Running
kubectl get pods -n kube-system

# Watch nodes come online
kubectl get nodes -w
```

---

## Lab 02 — Amazon EKS Managed Cluster

Full guide: [labs/lab-02-eks/README.md](labs/lab-02-eks/README.md)

### Step 1 — Install tools

```bash
chmod +x labs/lab-02-eks/install-eksctl.sh
./labs/lab-02-eks/install-eksctl.sh
```

Installs **eksctl**, **kubectl**, and **AWS CLI v2** on Linux, macOS, or Windows (Git Bash). Idempotent — skips tools already installed.

Verify:

```bash
eksctl version    # → 0.225.0 or later
kubectl version --client
aws --version
```

### Step 2 — Configure AWS credentials

```bash
aws configure --profile sarowar-ostad
# Region: ap-south-1
```

### Step 3 — Review the cluster config

[labs/lab-02-eks/cluster-config.yaml](labs/lab-02-eks/cluster-config.yaml) is the single source of truth for the entire cluster:

| Key field | Value | Why |
|---|---|---|
| `metadata.name` | `k8s-demo-eks` | Cluster name in AWS Console |
| `metadata.version` | `1.35` | Latest stable EKS release |
| `iam.withOIDC` | `true` | Enables IRSA — pods get IAM roles without static keys |
| `vpc.cidr` | `192.168.0.0/16` | Non-overlapping with devops-vpc (`10.0.0.0/16`) |
| `vpc.nat.gateway` | `Single` | Cost-optimised; change to `HighlyAvailable` for production |
| `nodeGroups.instanceType` | `t3.medium` | 2 vCPU / 4 GB — minimum for reliable cluster operation |
| `nodeGroups.ami` | AmazonLinux2023 | Required for K8s 1.30+; AL2 is end-of-life |
| `nodeGroups.privateNetworking` | `true` | Workers in private subnets — no direct internet exposure |

### Step 4 — Create the cluster

```bash
eksctl create cluster -f labs/lab-02-eks/cluster-config.yaml
```

Duration: **15–20 minutes**. eksctl provisions two CloudFormation stacks (VPC + cluster) and auto-updates your kubeconfig.

Estimated cost while running:

| Resource | Cost |
|---|---|
| EKS control plane | ~$0.10/hr |
| 1× t3.medium worker | ~$0.04/hr |
| Single NAT Gateway | ~$0.06/hr |
| **Total** | **~$0.20/hr** |

> Always delete the cluster when done — see [Teardown](#teardown).

### Step 5 — Verify

```bash
kubectl config current-context         # should show the EKS cluster ARN
kubectl cluster-info
kubectl get nodes                      # Ready within ~60 seconds
kubectl get pods -n kube-system        # vpc-cni, coredns, kube-proxy must be Running
eksctl get addon --cluster k8s-demo-eks  # all 4 addons: ACTIVE
```

### Connect from a new machine

If you need to manage the cluster from a different workstation:

```bash
# 1. Install tools (see Step 1)
# 2. Configure credentials (see Step 2)
# 3. Pull the kubeconfig
aws eks list-clusters --region ap-south-1 --profile sarowar-ostad
aws eks update-kubeconfig \
  --name k8s-demo-eks \
  --region ap-south-1 \
  --profile sarowar-ostad
kubectl get nodes
```

---

## Manifests — Progressive Resource Examples

Full guide: [manifests/README.md](manifests/README.md)

The manifests directory teaches Kubernetes resource types progressively. Each directory is self-contained and includes a dedicated section in the central guide.

```
manifests/
├── 01-pod/            ← Single-container and sidecar patterns
├── 02-replicaset/     ← Self-healing, manual scaling
├── 03-deployment/     ← Rolling updates, history, rollback, pause/resume
├── 04-service/        ← ClusterIP · NodePort · LoadBalancer (NLB on EKS)
├── 05-namespace/      ← dev + staging isolation, context switching
└── 06-static-site/    ← End-to-end: ConfigMap + Deployment + NodePort/NLB
```

### Apply all manifests

```bash
# Apply progressively (recommended for learning)
kubectl apply -f manifests/01-pod/
kubectl apply -f manifests/02-replicaset/
kubectl apply -f manifests/03-deployment/
kubectl apply -f manifests/04-service/
kubectl apply -f manifests/05-namespace/
kubectl apply -f manifests/06-static-site/

# EKS only — expose with LoadBalancer:
kubectl apply -f manifests/04-service/service-loadbalancer.yaml
kubectl apply -f manifests/06-static-site/service-loadbalancer.yaml
```

### Deploy the static site

The static site (`06-static-site`) is the capstone manifest — a full Kubernetes Learning Hub page served by nginx, with the HTML stored in a ConfigMap (no Docker build required):

**kubeadm:**
```bash
kubectl apply -f manifests/06-static-site/configmap.yaml
kubectl apply -f manifests/06-static-site/deployment.yaml
kubectl apply -f manifests/06-static-site/service-nodeport.yaml

# Get node IP
kubectl get nodes -o wide    # EXTERNAL-IP column

# Access (open port 30090 in EC2 Security Group first)
curl http://<node-public-ip>:30090
```

**EKS:**
```bash
kubectl apply -f manifests/06-static-site/
# Wait ~90 seconds for NLB
kubectl get svc static-site-lb -w
curl http://<EXTERNAL-IP>
```

### Update site content without redeploying

```bash
kubectl edit configmap static-site-html
kubectl rollout restart deployment/static-site
kubectl rollout status deployment/static-site
```

---

## Switching Between Clusters

Both clusters can be managed from the same machine by switching kubectl contexts:

```bash
# List all available contexts
kubectl config get-contexts

# Switch to EKS
kubectl config use-context <eks-arn-context>

# Switch to kubeadm
kubectl config use-context kubernetes-admin@kubernetes

# Show active context
kubectl config current-context
```

---

## Making Changes Safely

### Manifests

All manifests support `kubectl apply` (declarative, idempotent):

```bash
# Dry-run before applying — shows what will change without touching the cluster
kubectl apply -f manifests/03-deployment/deployment.yaml --dry-run=server

# Diff against live cluster
kubectl diff -f manifests/03-deployment/deployment.yaml

# Apply with record (shows up in rollout history)
kubectl apply -f manifests/03-deployment/deployment.yaml
kubectl annotate deployment/nginx-deployment \
  kubernetes.io/change-cause="describe change here" --overwrite
```

### Rolling back a deployment

```bash
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>                  # revert to previous
kubectl rollout undo deployment/<name> --to-revision=N # revert to specific
kubectl rollout status deployment/<name>               # watch recovery
```

### Editing the cluster config (EKS)

Edit `labs/lab-02-eks/cluster-config.yaml`, then:

```bash
# Preview changes
eksctl upgrade cluster -f labs/lab-02-eks/cluster-config.yaml --dry-run

# Apply (for node group changes, eksctl may replace nodes)
eksctl upgrade cluster -f labs/lab-02-eks/cluster-config.yaml
```

### Upgrading Kubernetes versions

**kubeadm:**

```bash
# On master node — unhold, upgrade, re-hold
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get install -y kubeadm=1.30.0-* kubelet=1.30.0-* kubectl=1.30.0-*
sudo apt-mark hold kubeadm kubelet kubectl
sudo kubeadm upgrade apply v1.30.0
sudo systemctl restart kubelet
```

**EKS:** Update `metadata.version` in `cluster-config.yaml`, then:

```bash
eksctl upgrade cluster -f labs/lab-02-eks/cluster-config.yaml
```

### Node maintenance (kubeadm)

```bash
# Safely evict all pods before maintenance
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Perform maintenance, then mark schedulable again
kubectl uncordon <node-name>
```

### Scripts are idempotent

All shell scripts (`provision-ec2.sh`, `master-init.sh`, `worker-join.sh`, `install-eksctl.sh`) check state before acting. Re-running after a partial failure is safe — completed steps are skipped.

---

## Reliability and Operational Considerations

### kubeadm cluster

| Topic | Detail |
|---|---|
| **Join token expiry** | `kubeadm join` tokens expire after **24 hours**. Regenerate: `kubeadm token create --print-join-command` |
| **etcd** | Single-node etcd (no HA). Losing the master node loses the cluster. Back up etcd for production: `etcdctl snapshot save` |
| **Certificates** | Auto-renewed by kubeadm annually. Monitor expiry: `kubeadm certs check-expiration` |
| **Calico** | Requires TCP 179 (BGP) and UDP 4789 (VXLAN) open between nodes in the security group |
| **Pod CIDR conflicts** | `192.168.0.0/16` must not overlap with your VPC CIDR or on-premises networks |
| **Swap** | Must remain disabled. kubelet enforces this. If a node reboots and swap is re-enabled, kubelet will fail to start |

### EKS cluster

| Topic | Detail |
|---|---|
| **Control plane SLA** | AWS guarantees 99.95% API availability — no master node maintenance required |
| **Worker node updates** | Update via eksctl or node group rolling replacement; use `kubectl drain` first |
| **IRSA** | Pods access AWS services via IAM roles attached to Service Accounts — no static credentials in any manifest |
| **NAT Gateway (Single)** | A single NAT Gateway failure cuts all worker node outbound traffic. Use `gateway: HighlyAvailable` in production |
| **LoadBalancer services** | Each creates an AWS NLB (~$0.008/hr + data). Use an Ingress controller (e.g., AWS LB Controller) to share one NLB across many services |
| **Cluster deletion** | `eksctl delete cluster` tears down the entire VPC, all nodes, all addons, and all stacks. LoadBalancer services must be deleted first or the VPC deletion will hang |

### General

| Topic | Detail |
|---|---|
| **Resource limits** | All manifests specify `requests` and `limits`. Never deploy without them — unbounded pods cause node OOM events |
| **NodePort range** | 30000–32767. Port 30080 (04-service examples) and 30090 (06-static-site) must be open in the node security group |
| **Credentials** | `.pem`, `.key`, `.env` files are in `.gitignore`. Never commit AWS credentials or private keys |
| **Context awareness** | Always run `kubectl config current-context` before applying manifests. Applying EKS-only resources (NLB) to kubeadm hangs silently |

---

## Teardown

### kubeadm cluster

```bash
# From your local machine — terminates all EC2 instances
cd labs/lab-01-kubeadm
bash provision-ec2.sh --teardown
```

### EKS cluster

> **Important:** Delete any LoadBalancer services before deleting the cluster, otherwise the VPC deletion will hang waiting for the NLB to be deprovisioned.

```bash
# Delete LoadBalancer services first
kubectl delete -f manifests/06-static-site/service-loadbalancer.yaml
kubectl delete -f manifests/04-service/service-loadbalancer.yaml

# Delete cluster + all VPC/networking (15–20 min)
eksctl delete cluster -f labs/lab-02-eks/cluster-config.yaml
```

### Manifests only

```bash
kubectl delete -f manifests/06-static-site/
kubectl delete -f manifests/05-namespace/namespace.yaml
kubectl delete -f manifests/04-service/
kubectl delete -f manifests/03-deployment/deployment.yaml
kubectl delete -f manifests/02-replicaset/replicaset.yaml
kubectl delete -f manifests/01-pod/
```

---

## Reference

| Resource | Link |
|---|---|
| kubectl cheatsheet (this repo) | [kubectl-cheatsheet.md](kubectl-cheatsheet.md) |
| manifests guide | [manifests/README.md](manifests/README.md) |
| lab-01 full guide | [labs/lab-01-kubeadm/README.md](labs/lab-01-kubeadm/README.md) |
| lab-02 full guide | [labs/lab-02-eks/README.md](labs/lab-02-eks/README.md) |
| Kubernetes official docs | https://kubernetes.io/docs/ |
| kubectl cheatsheet (official) | https://kubernetes.io/docs/reference/kubectl/cheatsheet/ |
| kubeadm reference | https://kubernetes.io/docs/reference/setup-tools/kubeadm/ |
| eksctl documentation | https://eksctl.io/ |
| AWS EKS user guide | https://docs.aws.amazon.com/eks/latest/userguide/ |
| Calico docs | https://docs.tigera.io/calico/latest/ |

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
