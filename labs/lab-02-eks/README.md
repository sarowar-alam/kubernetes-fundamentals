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

- AWS CLI v2 installed and configured with profile `sop`
- `eksctl` installed (see `install-eksctl.sh`)
- `kubectl` installed (`kubectl version --client`)
- IAM user/role with admin or EKS full access permissions

### Verify tools are ready

```bash
# Check AWS CLI and profile
aws sts get-caller-identity --profile sop

# Check eksctl
eksctl version

# Check kubectl
kubectl version --client
```

---

## Step 1 — Install eksctl

```bash
chmod +x labs/lab-02-eks/install-eksctl.sh
./labs/lab-02-eks/install-eksctl.sh
```

**What is eksctl?**  
eksctl is the official command-line tool for EKS. It reads a YAML config file (like the one we have) and makes hundreds of AWS API calls for you — creating VPCs, security groups, IAM roles, the EKS cluster, and EC2 node groups.

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
  name: k8s-demo-eks   # Name visible in AWS Console
  region: ap-south-1        # Mumbai region
  version: "1.29"           # Kubernetes version
```

**Real-world tip:** Always pin the K8s version. Never use `latest`. Upgrades should be planned, tested, not accidental.

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

#### `managedNodeGroups` block

```yaml
instanceType: t3.medium   # Worker node size
minSize: 1                 # Always keep 1 node alive
maxSize: 3                 # Auto-scale up to 3 during load
desiredCapacity: 2         # Start with 2 nodes
```

**Cost insight:** You pay for nodes, not the control plane (well, $0.10/hr for the cluster, but nodes are the real cost). Setting `maxSize: 3` means your AWS bill never scales beyond 3x t3.medium without your knowing.

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
| `eksctl create cluster` fails on IAM permissions | Check: `aws iam get-user --profile sop` → ensure admin or EKS policies |
| `kubectl` shows wrong cluster | `kubectl config use-context <eks-context-name>` |
| LoadBalancer stuck in `<pending>` | Wait 90 seconds; check `kubectl describe svc nginx-eks` for events |
| Nodes not joining the cluster | Check CloudFormation stack for the node group — look at Events tab |
| eksctl delete cluster hangs | Check CloudFormation in AWS Console and delete stacks manually if needed |
