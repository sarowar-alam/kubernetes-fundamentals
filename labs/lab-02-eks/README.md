# lab-02-eks — Managed Kubernetes on AWS EKS with eksctl

Provision, operate, and tear down a production-architecture EKS cluster on AWS using **eksctl** and a declarative YAML config. The cluster adheres to AWS best practices: private worker nodes, a single managed NAT Gateway, OIDC-enabled IRSA, and a fully managed AWS add-on stack.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Technology Stack](#2-technology-stack)
3. [Directory Layout](#3-directory-layout)
4. [Prerequisites](#4-prerequisites)
5. [Step 1 — Install Tools](#5-step-1--install-tools)
6. [Step 2 — Configure AWS Credentials](#6-step-2--configure-aws-credentials)
7. [Step 3 — Review the Cluster Config](#7-step-3--review-the-cluster-config)
8. [Step 4 — Create the EKS Cluster](#8-step-4--create-the-eks-cluster)
9. [Step 5 — Verify the Cluster](#9-step-5--verify-the-cluster)
10. [Step 6 — Deploy a Test Application](#10-step-6--deploy-a-test-application)
11. [Step 7 — Connect an Existing Cluster to a New Machine](#11-step-7--connect-an-existing-cluster-to-a-new-machine)
12. [Step 8 — Switching Between Clusters](#12-step-8--switching-between-clusters)
13. [Operational Reference](#13-operational-reference)
14. [Making Changes Safely](#14-making-changes-safely)
15. [Step 9 — Delete the Cluster](#15-step-9--delete-the-cluster)
16. [Design Decisions](#16-design-decisions)
17. [kubeadm vs EKS Comparison](#17-kubeadm-vs-eks-comparison)
18. [Troubleshooting](#18-troubleshooting)

---

## 1. Architecture Overview

```
AWS ap-south-1
│
└── eksctl-managed VPC  192.168.0.0/16
    │
    ├── ap-south-1a
    │   ├── Public subnet  192.168.0.0/19   ← Internet Gateway
    │   │                                    ← NAT Gateway (Single, shared)
    │   │                                    ← AWS Load Balancers (when created)
    │   └── Private subnet 192.168.96.0/19  ← worker nodes
    │
    ├── ap-south-1b
    │   ├── Public subnet  192.168.32.0/19
    │   └── Private subnet 192.168.128.0/19 ← worker nodes
    │
    └── ap-south-1c
        ├── Public subnet  192.168.64.0/19
        └── Private subnet 192.168.160.0/19 ← worker nodes
              │
              └── EKS Managed Node Group "workers"
                    • t3.medium (2 vCPU / 4 GB RAM)
                    • AmazonLinux2023
                    • gp3 root volume, EBS-optimised
                    • 1 desired / 1 min / 2 max
                    • SSH via key pair  sarowar-ostad-mumbai

EKS Control Plane (AWS-managed, not visible as EC2 instances)
  • kube-apiserver  — public + private endpoint
  • etcd            — AWS-managed, backed up automatically
  • kube-scheduler / kube-controller-manager

AWS-Managed Add-ons
  • vpc-cni           — pod networking (real VPC IPs)
  • coredns           — cluster DNS
  • kube-proxy        — service traffic routing
  • aws-ebs-csi-driver — persistent volume provisioning
```

**Traffic flow for outbound node connectivity:**
```
Worker node (private subnet)
  → NAT Gateway (public subnet, single AZ)
  → Internet Gateway
  → EKS API / ECR / OS updates
```

**Traffic flow for inbound application traffic:**
```
Internet → AWS Load Balancer (public subnet)
         → Service (NodePort/ClusterIP)
         → Pods (private subnet)
```

---

## 2. Technology Stack

| Layer | Technology | Version / Detail |
|---|---|---|
| Cloud | AWS | ap-south-1 (Mumbai) |
| Cluster orchestration | Amazon EKS | Kubernetes 1.35 |
| Cluster provisioner | eksctl | 0.225.0+ |
| Kubernetes CLI | kubectl | latest stable (v1.35.x) |
| AWS CLI | AWS CLI v2 | 2.x |
| Node OS | Amazon Linux 2023 | Required for K8s 1.30+ |
| Container runtime | containerd | Managed by AWS |
| Pod networking | AWS VPC CNI (vpc-cni) | latest |
| DNS | CoreDNS | latest |
| Storage driver | aws-ebs-csi-driver | latest |
| Node volume type | gp3 EBS, 20 GB | EBS-optimised |
| IAM Auth | OIDC / IRSA | Enabled |
| Config format | eksctl ClusterConfig v1alpha5 | — |

---

## 3. Directory Layout

```
labs/lab-02-eks/
├── install-eksctl.sh    # Installs eksctl + kubectl + AWS CLI v2 (Linux/macOS/Windows)
├── cluster-config.yaml  # Declarative EKS cluster definition — the single source of truth
└── README.md            # This file
```

### File responsibilities

**`install-eksctl.sh`**
- Detects the OS (Linux, macOS, Windows Git Bash) and architecture (amd64/arm64)
- Checks each tool individually — idempotent, skips already-installed tools
- Linux/macOS: downloads from official release URLs
- Windows: uses Chocolatey (`choco install eksctl kubernetes-cli awscli`)
- Installs `unzip` automatically on Linux if missing (required for AWS CLI)

**`cluster-config.yaml`**
- Authoritative cluster definition read by eksctl
- Creates and owns the entire VPC lifecycle — `eksctl delete cluster` removes all networking
- All parameters are commented inline

---

## 4. Prerequisites

### Local machine (laptop / workstation)

| Requirement | Check |
|---|---|
| AWS account with IAM permissions (see below) | `aws sts get-caller-identity` |
| EC2 Key Pair in ap-south-1 named `sarowar-ostad-mumbai` | AWS Console → EC2 → Key Pairs |
| Internet access to download binaries | — |

### IAM permissions required

The IAM identity running eksctl needs at minimum:

```
AmazonEKSClusterPolicy
AmazonEKSWorkerNodePolicy
AmazonEC2FullAccess
AmazonVPCFullAccess
IAMFullAccess
AWSCloudFormationFullAccess
```

For simplicity in a lab environment, `AdministratorAccess` satisfies all of these.

### Tools — installed by `install-eksctl.sh`

| Tool | Purpose | Minimum version |
|---|---|---|
| `aws` | Authentication; `update-kubeconfig` | 2.x |
| `eksctl` | Create/delete/manage EKS clusters | 0.200+ |
| `kubectl` | Send commands to the Kubernetes API | matches cluster version |

---

## 5. Step 1 — Install Tools

Run once on any machine that will manage the cluster:

```bash
cd labs/lab-02-eks
chmod +x install-eksctl.sh
sudo ./install-eksctl.sh
```

The script checks each tool before installing — re-running is safe. On Windows (Git Bash), run without `sudo`.

### What the script installs per platform

| Tool | Linux | macOS | Windows Git Bash |
|---|---|---|---|
| eksctl | GitHub tarball → `/usr/local/bin` | GitHub tarball → `/usr/local/bin` | `choco install eksctl` |
| kubectl | `dl.k8s.io` binary → `/usr/local/bin` | `dl.k8s.io` binary → `/usr/local/bin` | `choco install kubernetes-cli` |
| AWS CLI v2 | Official zip → `/usr/local/bin/aws` | Official `.pkg` installer | `choco install awscli` |

### Verify installation

```bash
eksctl version
kubectl version --client
aws --version
```

---

## 6. Step 2 — Configure AWS Credentials

```bash
aws configure --profile sarowar-ostad
```

Enter when prompted:

```
AWS Access Key ID     : <your-key-id>
AWS Secret Access Key : <your-secret-key>
Default region name   : ap-south-1
Default output format : json
```

Verify authentication:

```bash
aws sts get-caller-identity --profile sarowar-ostad
```

Expected output includes your `Account` ID and `Arn`. If this fails, the key is wrong or expired.

> **On EC2 with an IAM instance role:** credentials are automatic. Skip `aws configure` and omit `--profile sarowar-ostad` from all commands — the instance role provides credentials transparently.

---

## 7. Step 3 — Review the Cluster Config

```bash
cat labs/lab-02-eks/cluster-config.yaml
```

### Key configuration values

| Field | Value | Notes |
|---|---|---|
| `metadata.name` | `k8s-demo-eks` | Cluster name in AWS Console |
| `metadata.region` | `ap-south-1` | Mumbai |
| `metadata.version` | `"1.35"` | Pin explicitly; never omit |
| `autoModeConfig.enabled` | `false` | Keeps managed node groups; prevents future eksctl default change |
| `iam.withOIDC` | `true` | Enables IRSA — pods get short-lived AWS credentials via Service Accounts |
| `vpc.cidr` | `192.168.0.0/16` | Non-overlapping with devops-vpc (`10.0.0.0/16`) |
| `vpc.nat.gateway` | `Single` | One shared NAT Gateway — cost-optimised for lab |
| `vpc.clusterEndpoints.publicAccess` | `true` | kubectl from laptop reaches the API |
| `vpc.clusterEndpoints.privateAccess` | `true` | Nodes reach API over private endpoint (required with private subnets) |
| `instanceType` | `t3.medium` | 2 vCPU / 4 GB RAM |
| `desiredCapacity` | `1` | Start with 1 node |
| `minSize` / `maxSize` | `1` / `2` | Auto Scaling Group bounds |
| `amiFamily` | `AmazonLinux2023` | Required for K8s 1.30+; AL2 is EOL |
| `volumeType` | `gp3` | Faster and cheaper than gp2 |
| `ebsOptimized` | `true` | Dedicated EBS bandwidth |
| `privateNetworking` | `true` | Nodes in private subnets; outbound via NAT |
| `ssh.publicKeyName` | `sarowar-ostad-mumbai` | Must exist in ap-south-1 |

### Why OIDC / IRSA matters

**Without OIDC:**
```
Pod needs S3 access → store AWS access key in a Kubernetes Secret
→ Key never rotates → leaked key = full account compromise risk
```

**With OIDC (IRSA):**
```
Pod needs S3 access → IAM Role attached to a Service Account
→ Pod receives temporary credentials (auto-rotated every hour)
→ No secrets in YAML, least-privilege by default
```

Enable `withOIDC: true` in every cluster you create.

### Add-ons explained

| Add-on | What breaks without it |
|---|---|
| `vpc-cni` | Pods cannot communicate with VPC resources; no real VPC IPs |
| `coredns` | Services cannot resolve by name (`my-svc.default.svc.cluster.local` fails) |
| `kube-proxy` | Service IPs don't route; traffic never reaches pods |
| `aws-ebs-csi-driver` | PersistentVolumeClaims fail; stateful apps (databases) cannot store data |

---

## 8. Step 4 — Create the EKS Cluster

```bash
cd labs/lab-02-eks
eksctl create cluster -f cluster-config.yaml --profile sarowar-ostad
```

**Expected duration: 15–20 minutes.**

### What eksctl provisions (in order)

```
1. CloudFormation Stack 1: eksctl-k8s-demo-eks-cluster
   ├── VPC  192.168.0.0/16
   ├── 3x public subnets + 3x private subnets (6 total across 3 AZs)
   ├── Internet Gateway
   ├── NAT Gateway (1x, in ap-south-1a public subnet)
   ├── Route tables
   ├── Security groups
   ├── EKS Control Plane
   ├── OIDC Identity Provider (IAM)
   └── AWS-managed add-ons (vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver)

2. CloudFormation Stack 2: eksctl-k8s-demo-eks-nodegroup-workers
   ├── EC2 Launch Template (AmazonLinux2023, gp3, EBS-optimised)
   ├── Auto Scaling Group (min:1, desired:1, max:2)
   └── Worker nodes registered with the cluster
```

eksctl also writes the cluster context to `~/.kube/config` automatically.

### Monitor progress

While it runs, observe in the AWS Console:
- **CloudFormation** → two stacks appearing with `CREATE_IN_PROGRESS` status
- **EKS** → cluster status: `CREATING` → `ACTIVE`
- **EC2** → 1x t3.medium instance launching in a private subnet

**Expected final output:**
```
[✔]  EKS cluster "k8s-demo-eks" in "ap-south-1" region is ready
```

---

## 9. Step 5 — Verify the Cluster

```bash
# Current kubeconfig context (should show the EKS cluster)
kubectl config current-context

# Control plane endpoint
kubectl cluster-info

# Worker nodes (Ready within ~60s of cluster creation)
kubectl get nodes -o wide

# All system pods should be Running or Completed
kubectl get pods -n kube-system

# Confirm all four add-ons are running
kubectl get pods -n kube-system | grep -E "coredns|kube-proxy|aws-node|ebs-csi"
```

Expected node output:
```
NAME                                              STATUS   ROLES    AGE   VERSION
ip-192-168-xxx-xxx.ap-south-1.compute.internal   Ready    <none>   2m    v1.35.x
```

---

## 10. Step 6 — Deploy a Test Application

```bash
# Deploy nginx
kubectl create deployment nginx-eks --image=nginx:alpine --replicas=2

# Wait for rollout
kubectl rollout status deployment/nginx-eks

# Expose via AWS Load Balancer (EKS provisions a real NLB automatically)
kubectl expose deployment nginx-eks --port=80 --type=LoadBalancer

# Watch for the external DNS name — takes ~90 seconds
kubectl get service nginx-eks --watch
```

Once `EXTERNAL-IP` shows a DNS hostname:

```bash
curl http://<EXTERNAL-IP>
```

**Why this works on EKS but not kubeadm:**
EKS integrates with the AWS load balancer controller. A `LoadBalancer` service triggers AWS to provision a real Network Load Balancer pointing to your pods. On a bare kubeadm cluster there is no cloud integration, so `EXTERNAL-IP` stays `<pending>` indefinitely.

Clean up after testing:
```bash
kubectl delete service nginx-eks
kubectl delete deployment nginx-eks
```

---

## 11. Step 7 — Connect an Existing Cluster to a New Machine

If the cluster already exists and you are setting up a new machine (e.g. a new EC2 jump host), no cluster creation is needed.

### 1. Install tools

```bash
sudo ./install-eksctl.sh
```

### 2. Configure AWS credentials

```bash
aws configure --profile sarowar-ostad
# Or skip if the machine has an IAM instance role
```

### 3. Find the cluster name

```bash
aws eks list-clusters --region ap-south-1 --profile sarowar-ostad
```

### 4. Update kubeconfig

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name k8s-demo-eks \
  --profile sarowar-ostad
```

This writes the cluster endpoint, CA certificate, and `aws eks get-token` authentication command into `~/.kube/config`.

### 5. Verify

```bash
kubectl get nodes
kubectl get pods -A
```

### Troubleshooting: `Unauthorized` error

The IAM identity is not mapped to Kubernetes RBAC. Run from a machine that already has cluster admin access:

**For an IAM user:**
```bash
eksctl create iamidentitymapping \
  --cluster k8s-demo-eks \
  --region ap-south-1 \
  --arn arn:aws:iam::<account-id>:user/<iam-username> \
  --group system:masters \
  --profile sarowar-ostad
```

**For an IAM role (EC2 instance role):**
```bash
eksctl create iamidentitymapping \
  --cluster k8s-demo-eks \
  --region ap-south-1 \
  --arn arn:aws:iam::<account-id>:role/<role-name> \
  --group system:masters \
  --profile sarowar-ostad
```

---

## 12. Step 8 — Switching Between Clusters

If you also have a kubeadm cluster from lab-01, kubectl uses **contexts** to switch between them.

```bash
# List all available contexts
kubectl config get-contexts

# Switch to EKS
kubectl config use-context k8s-demo-eks.ap-south-1.eksctl.io

# Switch to kubeadm cluster
kubectl config use-context kubernetes-admin@kubernetes

# Confirm which cluster you are talking to
kubectl config current-context
kubectl cluster-info
```

---

## 13. Operational Reference

### Scale the node group

```bash
# Scale to 2 nodes immediately
eksctl scale nodegroup \
  --cluster k8s-demo-eks \
  --name workers \
  --nodes 2 \
  --profile sarowar-ostad
```

### Add a new node group

Add a second entry under `managedNodeGroups` in `cluster-config.yaml`, then:

```bash
eksctl create nodegroup \
  --config-file cluster-config.yaml \
  --include <new-nodegroup-name> \
  --profile sarowar-ostad
```

### Upgrade Kubernetes version

1. Update `metadata.version` in `cluster-config.yaml`
2. Run:
```bash
eksctl upgrade cluster \
  --config-file cluster-config.yaml \
  --approve \
  --profile sarowar-ostad

# Then upgrade node groups
eksctl upgrade nodegroup \
  --cluster k8s-demo-eks \
  --name workers \
  --profile sarowar-ostad
```

Upgrade one minor version at a time (e.g. 1.35 → 1.36). Skipping versions is unsupported.

### Upgrade add-ons

```bash
eksctl update addon \
  --cluster k8s-demo-eks \
  --name vpc-cni \
  --profile sarowar-ostad
# Repeat for coredns, kube-proxy, aws-ebs-csi-driver
```

### Get cluster info

```bash
eksctl get cluster --profile sarowar-ostad --region ap-south-1
eksctl get nodegroup --cluster k8s-demo-eks --profile sarowar-ostad
```

### SSH into a worker node (for debugging)

Worker nodes are in private subnets — they have no public IP. SSH via a bastion or using AWS SSM:

```bash
# Via SSM Session Manager (no open SSH port needed, requires SSM agent on node)
aws ssm start-session \
  --target <instance-id> \
  --profile sarowar-ostad \
  --region ap-south-1

# Via SSH jump through a public bastion
ssh -J ubuntu@<bastion-public-ip> \
    -i ~/.ssh/sarowar-ostad-mumbai.pem \
    ec2-user@<node-private-ip>
```

### Key file locations

| Path | Purpose |
|---|---|
| `~/.kube/config` | kubeconfig — cluster contexts, credentials |
| `~/.aws/credentials` | AWS credentials by profile |
| `~/.aws/config` | AWS region/output config by profile |
| `cluster-config.yaml` | Source of truth for the EKS cluster definition |

---

## 14. Making Changes Safely

### Modifying `cluster-config.yaml`

`cluster-config.yaml` is the source of truth. Changes fall into two categories:

| Type of change | How to apply |
|---|---|
| Cluster-level (version, addons, OIDC) | `eksctl upgrade cluster --config-file cluster-config.yaml --approve` |
| Node group changes (instanceType, size) | Cannot modify in place — create a new node group, drain old one, delete old one |
| Scaling (desired/min/max) | `eksctl scale nodegroup` (see above) — no stack replacement needed |
| Tags/labels | `eksctl update labels` / edit and re-apply config |

### Never delete and recreate for config changes

Deleting and recreating the cluster destroys all workloads, persistent volumes, and service endpoints. Use `eksctl upgrade` for in-place updates.

### Drain nodes before maintenance

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
# Perform maintenance ...
kubectl uncordon <node-name>
```

---

## 15. Step 9 — Delete the Cluster

> **Always delete after use to stop billing.**

```bash
eksctl delete cluster -f cluster-config.yaml --profile sarowar-ostad
```

**Duration: ~5 minutes.**

This removes everything eksctl created:
- EKS control plane
- EC2 worker nodes (Auto Scaling Group)
- NAT Gateway + Elastic IP
- Internet Gateway
- All subnets, route tables, security groups
- VPC
- CloudFormation stacks
- IAM roles for node groups and add-ons

**Estimated cost if left running:**

| Component | Rate |
|---|---|
| EKS control plane | $0.10/hr |
| 1x t3.medium node | ~$0.04/hr |
| NAT Gateway | ~$0.06/hr + data |
| **Total** | **~$0.20/hr (~$144/month)** |

After deletion, verify in AWS Console:
- CloudFormation → both stacks deleted
- EKS → cluster gone
- EC2 → no instances from this cluster
- VPC → eksctl VPC removed

---

## 16. Design Decisions

| Decision | Rationale |
|---|---|
| eksctl over Terraform/CDK | Lower learning curve; single file covers all EKS concerns; purpose-built for EKS |
| eksctl-managed VPC | Full lifecycle ownership — `delete cluster` removes all networking; no orphaned resources |
| `privateNetworking: true` | Nodes not internet-routable; reduces attack surface; matches production practice |
| Single NAT Gateway | Cost-optimised for lab (~$0.06/hr vs ~$0.18/hr for HighlyAvailable); acceptable SPOF for non-production |
| `publicAccess + privateAccess` both `true` | Allows both laptop kubectl access and secure node-to-API communication over private endpoint |
| `autoModeConfig.enabled: false` | Keeps deterministic behaviour as eksctl evolves; Auto Mode is opt-in |
| `withOIDC: true` | Industry-standard approach to pod-level AWS permissions; eliminates need for access keys in workloads |
| `amiFamily: AmazonLinux2023` | Amazon Linux 2 is EOL for K8s 1.30+; AL2023 is the supported replacement |
| `gp3` + `ebsOptimized: true` | gp3 baseline throughput is higher than gp2 at the same price; EBS optimisation eliminates I/O contention |
| `apt-mark`-equivalent on add-ons via `version: latest` | Add-on versions are managed by AWS per cluster version; `latest` ensures compatibility without manual pinning |

---

## 17. kubeadm vs EKS Comparison

| Aspect | kubeadm (lab-01) | EKS (lab-02) |
|---|---|---|
| Control plane setup | Manual, ~45 min | AWS-managed, ~15 min |
| etcd backup | Your responsibility | AWS manages automatically |
| Master node patching | Your responsibility | AWS patches automatically |
| AWS LoadBalancer service | Does not work | Creates real AWS NLB |
| PersistentVolumes | Manual driver setup | aws-ebs-csi-driver addon |
| Node scaling | Manual EC2 + kubeadm join | eksctl / Auto Scaling Group |
| OIDC / IRSA | Not built-in | Native, one flag |
| Upgrade path | Complex, manual drain/upgrade | `eksctl upgrade cluster` |
| Cost (1 node, 2 hr) | ~$0.08 (EC2 only) | ~$0.40 (EC2 + NAT + control plane) |
| Production readiness | Requires significant hardening | Production-grade out of the box |
| When to use | On-prem, bare metal, full control | AWS workloads, faster delivery |

---

## 18. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `invalid version, 1.29 is no longer supported` | Outdated version in config | Update `metadata.version` to a supported value (`1.30`–`1.35`) |
| `AmazonLinux2 is not supported for Kubernetes version 1.35` | AL2 EOL | Set `amiFamily: AmazonLinux2023` |
| `cannot find EC2 key pair "k8s-lab-key"` | Wrong key pair name | Check key pairs in ap-south-1; update `ssh.publicKeyName` |
| `Stack already exists` | Previous failed create left a stack | Run `eksctl delete cluster --name k8s-demo-eks --region ap-south-1 --profile sarowar-ostad --wait`, then retry |
| `The maximum number of VPCs has been reached` | VPC limit (default 5) hit | Delete an unused VPC or request a limit increase via AWS Support |
| `Unauthorized` on kubectl | IAM identity not in cluster RBAC | Run `eksctl create iamidentitymapping` from an admin machine (see Step 7) |
| Nodes stuck `NotReady` | Add-ons not yet running | Wait 2 min; check `kubectl get pods -n kube-system` |
| `LoadBalancer` service stuck `<pending>` | NLB provisioning delay | Wait 90 s; check `kubectl describe svc <name>` for events |
| `eksctl delete cluster` hangs | CloudFormation dependency issue | Open AWS Console → CloudFormation → delete stacks manually |
| `error: unknown field "ssm"` | Invalid field in `withAddonPolicies` | Remove `ssm:` — it is not a valid eksctl addon policy key |


---

## What is Amazon EKS?

EKS (Elastic Kubernetes Service) is AWS's **managed Kubernetes service**.

| Your Responsibility (kubeadm) | AWS Responsibility (EKS) |
|---|---|
| Provision EC2 instances | AWS provisions master nodes |
| Install kubeadm, kubelet | Pre-installed and managed by AWS |
| Run kubeadm init | AWS runs and manages the control plane |
| Patch master OS | AWS patches master nodes automatically |
| Back up etcd | AWS backs up etcd automatically |
| Scale master nodes | AWS scales masters automatically |
| Upgrade Kubernetes version | You click a button; AWS handles the rest |

**Real-world decision:** Use kubeadm when you need full control (on-premises, custom hardware). Use EKS when you're on AWS and want to focus on applications, not infrastructure.

---

## Prerequisites

- AWS CLI v2, `eksctl`, and `kubectl` installed — run `install-eksctl.sh` to get all three
- AWS profile `sarowar-ostad` configured (`aws configure --profile sarowar-ostad`)
- IAM user/role with admin or EKS full access permissions

### Verify tools are ready

```bash
# Check AWS CLI and profile
aws sts get-caller-identity --profile sarowar-ostad

# Check eksctl
eksctl version

# Check kubectl
kubectl version --client
```

---

## Connect to an Existing EKS Cluster

If an EKS cluster is already running in your AWS account and you need to configure a new machine to manage it, follow these steps. No cluster creation is required.

### 1. Configure AWS credentials

If the machine has an IAM instance role attached (e.g. the `SSM` profile), credentials are automatic — skip to step 2.

Otherwise, configure a named profile:

```bash
aws configure --profile sarowar-ostad
# Prompts for: Access Key ID, Secret Access Key, region (ap-south-1), output (json)
```

Verify authentication:
```bash
aws sts get-caller-identity --profile sarowar-ostad
```

### 2. Find the cluster name

```bash
aws eks list-clusters --region ap-south-1 --profile sarowar-ostad
```

### 3. Update kubeconfig

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name <your-cluster-name> \
  --profile sarowar-ostad
```

This writes the cluster endpoint, CA certificate, and authentication token command into `~/.kube/config`. If a context for this cluster already exists, it is overwritten.

### 4. Verify access

```bash
kubectl get nodes
kubectl get pods -A
```

---

### Troubleshooting: `Unauthorized` error

If `kubectl get nodes` returns `error: You must be logged in to the server (Unauthorized)`, the IAM identity used does not have access to the cluster's Kubernetes RBAC.

Fix — run this from a machine that already has admin access to the cluster:

```bash
eksctl create iamidentitymapping \
  --cluster <your-cluster-name> \
  --region ap-south-1 \
  --arn arn:aws:iam::<account-id>:user/<iam-username> \
  --group system:masters \
  --profile sarowar-ostad
```

For an IAM role (e.g. an EC2 instance role):
```bash
eksctl create iamidentitymapping \
  --cluster <your-cluster-name> \
  --region ap-south-1 \
  --arn arn:aws:iam::<account-id>:role/<role-name> \
  --group system:masters \
  --profile sarowar-ostad
```

---

## Step 1 — Install Tools

`install-eksctl.sh` installs all three required tools in one run:

| Tool | Purpose |
|---|---|
| `eksctl` | Creates/deletes EKS clusters from a YAML config |
| `kubectl` | Sends commands to the Kubernetes API (deploy, scale, inspect) |
| `aws` | Authenticates to AWS; used by eksctl and to update kubeconfig |

Each tool is checked first — if already installed, it is skipped.

```bash
chmod +x labs/lab-02-eks/install-eksctl.sh
sudo ./labs/lab-02-eks/install-eksctl.sh
```

**What is eksctl?**  
eksctl is the official command-line tool for EKS. It reads a YAML config file (like the one we have) and makes hundreds of AWS API calls for you — creating VPCs, NAT gateways, security groups, IAM roles, the EKS cluster, and EC2 node groups.

---

## Step 2 — Review the Cluster Config File

Open the annotated config file and read through every comment:

```bash
cat labs/lab-02-eks/cluster-config.yaml
```

### Field-by-Field Explanation

#### `metadata` block
```yaml
metadata:
  name: k8s-demo-eks    # Name visible in AWS Console → EKS → Clusters
  region: ap-south-1    # Mumbai region
  version: "1.35"       # Kubernetes version — always pin, never use 'latest'
```

**Real-world tip:** Upgrade one minor version at a time (e.g. 1.35 → 1.36). Skipping versions is unsupported and can break the cluster.

---

#### `iam.withOIDC: true`

This is one of the most important fields.

**Without OIDC:**
```
Your Pod needs to read from S3
→ You create an AWS access key
→ You put it in a Kubernetes Secret
→ Pod reads the secret and uses the key
→ Risk: key gets leaked, never rotated, applies to the whole account
```

**With OIDC (IRSA):**
```
Your Pod needs to read from S3
→ You create an IAM Role with only S3 read permission
→ You attach the role to a Kubernetes Service Account
→ Pod gets temporary AWS credentials automatically (rotated every hour)
→ No secrets in YAML, no leaked keys, least-privilege by default
```

**Enable this in every production cluster.** Cost: $0.

---

#### `addons` block

These are pre-integrated plugins AWS maintains for you:

| Addon | Without It | With It |
|---|---|---|
| `vpc-cni` | Pods can't communicate with VPC | Pods get real VPC IPs |
| `coredns` | Services can't resolve by name | Full DNS works (`my-svc.default.svc.cluster.local`) |
| `kube-proxy` | Service IPs don't work | Traffic routing works |
| `aws-ebs-csi-driver` | Databases can't have persistent storage | EBS volumes attach automatically |

---

#### `autoModeConfig` block

```yaml
autoModeConfig:
  enabled: false
```

This disables eksctl Auto Mode, which preserves the current behaviour of creating managed node groups and addons explicitly. Without this flag, a future eksctl release will skip node group and addon creation by default.

---

#### `vpc` block

```yaml
vpc:
  cidr: "192.168.0.0/16"   # Non-overlapping with any existing VPC
  nat:
    gateway: Single          # One shared NAT Gateway (cost-optimised)
  clusterEndpoints:
    publicAccess: true       # kubectl from your laptop reaches the API
    privateAccess: true      # nodes inside VPC reach the API privately
```

eksctl creates and fully owns this VPC. Running `eksctl delete cluster` removes the VPC, subnets, NAT gateway, Internet Gateway, and route tables automatically — no manual cleanup needed.

`nat.gateway: Single` uses one NAT Gateway shared across all AZs (~$0.06/hr). Change to `HighlyAvailable` for production to avoid an AZ-level SPOF.

---

#### `managedNodeGroups` block

```yaml
instanceType: t3.medium    # 2 vCPU / 4 GB RAM — suitable for demos
minSize: 1                  # Always keep at least 1 node running
maxSize: 2                  # Auto-scale ceiling — caps your EC2 spend
desiredCapacity: 1          # Start with 1 node
amiFamily: AmazonLinux2023  # Required for Kubernetes 1.30+ (AL2 is EOL)
volumetype: gp3             # Faster and cheaper than gp2
ebsOptimized: true          # Dedicated EBS bandwidth per node
privateNetworking: true     # Nodes in private subnets; reach internet via NAT
```

**Cost insight:** EKS control plane is $0.10/hr regardless of node count. Nodes are the main cost driver. With `maxSize: 2` and `desiredCapacity: 1`, the cluster starts at ~$0.14/hr (1x t3.medium + NAT gateway).

---

## Step 3 — Create the EKS Cluster

```bash
eksctl create cluster -f labs/lab-02-eks/cluster-config.yaml
```

**This takes 15-20 minutes.** While it runs, switch to the AWS Console and observe:

1. **CloudFormation** → 2 stacks being created (cluster + nodegroup)
2. **EKS** → Cluster appears in "Creating" state
3. **EC2** → 2 t3.medium instances being launched

### What eksctl is doing behind the scenes

```
eksctl reads cluster-config.yaml
    ↓
Creates CloudFormation Stack 1: VPC, subnets, security groups
    ↓
Creates EKS Control Plane (master nodes — you don't see these)
    ↓
Creates OIDC Provider in IAM
    ↓
Installs addons (vpc-cni, coredns, kube-proxy, ebs-csi-driver)
    ↓
Creates CloudFormation Stack 2: EC2 Auto Scaling Group for node group
    ↓
Worker nodes register with the cluster
    ↓
Updates your ~/.kube/config with EKS context
```

**Expected output:**
```
[✓]  EKS cluster "k8s-demo-eks" in "ap-south-1" region is ready
```

---

## Step 4 — Configure kubectl

eksctl automatically updates your `~/.kube/config`. Verify:

```bash
# Show the current context (should point to EKS)
kubectl config current-context

# List all available contexts
kubectl config get-contexts

# Check cluster
kubectl cluster-info
```

Expected output:
```
Kubernetes control plane is running at https://xxxx.gr7.ap-south-1.eks.amazonaws.com
CoreDNS is running at https://xxxx.../api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

---

## Step 5 — Verify the Cluster

```bash
# Check nodes
kubectl get nodes

# Expected:
# NAME                                         STATUS   ROLES    AGE   VERSION
# ip-192-168-xx-xx.ap-south-1.compute.internal  Ready    <none>   2m    v1.29.x
# ip-192-168-xx-xx.ap-south-1.compute.internal  Ready    <none>   2m    v1.29.x

# Check all system pods
kubectl get pods -n kube-system

# Check addons
kubectl get pods -n kube-system | grep -E "coredns|kube-proxy|aws-node"
```

---

## Step 6 — Deploy an Application on EKS

```bash
# Deploy nginx
kubectl create deployment nginx-eks --image=nginx:alpine --replicas=2

# Wait for pods to be ready
kubectl rollout status deployment/nginx-eks

# Expose as LoadBalancer
# On EKS, this automatically creates an AWS NLB (Network Load Balancer)
kubectl expose deployment nginx-eks --port=80 --type=LoadBalancer

# Get the external URL (wait ~90 seconds for NLB to provision)
kubectl get service nginx-eks --watch
```

Once `EXTERNAL-IP` changes from `<pending>` to a DNS name:

```bash
# Test it
curl http://<EXTERNAL-IP>
```

**What happened?**  
EKS integrated with AWS. When you created a LoadBalancer service, EKS told AWS to provision a real Network Load Balancer and point it to your pods. In kubeadm Lab 1, this didn't work because there's no AWS integration.

---

## Step 7 — Switching Between Clusters

You now have two clusters: kubeadm and EKS. kubectl uses **contexts** to switch between them.

```bash
# List all contexts
kubectl config get-contexts

# Switch to kubeadm (self-managed)
kubectl config use-context kubernetes-admin@kubernetes

# Switch to EKS
kubectl config use-context k8s-demo-eks.ap-south-1.eksctl.io

# Check which one you're talking to
kubectl config current-context
kubectl cluster-info
```

---

## Step 8 — Delete the EKS Cluster

Delete the cluster after use to avoid ongoing charges.

```bash
eksctl delete cluster -f labs/lab-02-eks/cluster-config.yaml
```

This deletes everything eksctl created: VPC, subnets, security groups, IAM roles, EC2 nodes, and the EKS cluster.

**Expected output:**
```
[✓]  all cluster resources were deleted
```

Also verify in AWS Console:
- CloudFormation → both stacks are deleted
- EKS → cluster is gone
- EC2 → no running instances from this cluster

---

## Comparison: kubeadm vs EKS

| Aspect | kubeadm (Lab 1) | EKS (Lab 2) |
|---|---|---|
| Setup time | 45-90 min | 15-20 min |
| AWS integration | Manual | Automatic |
| LoadBalancer Service | Doesn't work | Creates real AWS NLB |
| Control plane | You manage | AWS manages |
| etcd backup | You do it | AWS does it |
| Master node patching | You do it | AWS does it |
| Cost (per run) | ~$0.12 | ~$0.36 |
| Production-suitable | Needs more work | Yes |
| Learning value | High (internals visible) | High (real-world) |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `eksctl create cluster` fails on IAM permissions | Check: `aws iam get-user --profile sarowar-ostad` → ensure admin or EKS policies |
| `kubectl` shows wrong cluster | `kubectl config use-context <eks-context-name>` |
| LoadBalancer stuck in `<pending>` | Wait 90 seconds; check `kubectl describe svc nginx-eks` for events |
| Nodes not joining the cluster | Check CloudFormation stack for the node group — look at Events tab |
| eksctl delete cluster hangs | Check CloudFormation in AWS Console and delete stacks manually if needed |
