# Lab 2 — AWS EKS Cluster with eksctl

**Duration:** ~60 minutes  
**Level:** Beginner-Intermediate  
**Region:** ap-south-1 (Mumbai)

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
