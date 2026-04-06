# kubectl Cheatsheet — Kubernetes Fundamentals

---

## Installation

### Linux / Ubuntu (worker machine or local)
```bash
# Download the latest stable binary
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Make it executable and move to PATH
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl

# Verify
kubectl version --client
```

### macOS (via Homebrew)
```bash
brew install kubectl
kubectl version --client
```

### Windows (via winget)
```powershell
winget install -e --id Kubernetes.kubectl
kubectl version --client
```

---

## kubeconfig — How kubectl Knows Which Cluster to Talk To

### What is kubeconfig?
`~/.kube/config` is a file that contains:
- Cluster connection details (API server URL, CA certificate)
- Credentials (certificates or tokens)
- Context (which cluster + user combination to use)

```bash
# View your current kubeconfig
kubectl config view

# Show current context (which cluster you're talking to)
kubectl config current-context

# List all available contexts
kubectl config get-contexts

# Switch to a different context
kubectl config use-context <context-name>

# Set a specific namespace as default for your context
kubectl config set-context --current --namespace=<namespace-name>
```

### After kubeadm init
```bash
# Copy admin credentials to your user's home directory (run on master node)
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### After eksctl create cluster
```bash
# eksctl does this automatically, but you can also run:
aws eks update-kubeconfig --name k8s-demo-eks --region ap-south-1 --profile sop
```

---

## Cluster Information

```bash
# Cluster endpoint + DNS
kubectl cluster-info

# All nodes in the cluster
kubectl get nodes

# Nodes with extra info (IP, OS, container runtime)
kubectl get nodes -o wide

# Detailed info about a specific node (CPU, memory, pods running)
kubectl describe node <node-name>

# All namespaces
kubectl get namespaces

# All resources everywhere (God mode — use carefully)
kubectl get all --all-namespaces
```

---

## Working with Pods

### Creating Pods
```bash
# Quick way — run a pod from CLI (good for testing)
kubectl run mypod --image=nginx:alpine

# Create pod from YAML file
kubectl apply -f manifests/01-pod/pod-basic.yaml

# Run a pod and immediately get a shell inside it
kubectl run -it debug-pod --image=busybox --restart=Never -- /bin/sh
```

### Inspecting Pods
```bash
# List all pods in the default namespace
kubectl get pods

# Include system pods
kubectl get pods -n kube-system

# Pods in ALL namespaces
kubectl get pods --all-namespaces

# Pods with extra info (which node they're on, pod IP)
kubectl get pods -o wide

# Watch pods in real time (Ctrl+C to exit)
kubectl get pods -w

# Detailed pod info — events, status, conditions
kubectl describe pod <pod-name>

# Show pod labels
kubectl get pods --show-labels

# Filter pods by label
kubectl get pods -l app=nginx
```

### Debugging Pods
```bash
# Get logs from a pod
kubectl logs <pod-name>

# Logs for a specific container in a multi-container pod
kubectl logs <pod-name> -c <container-name>

# Stream logs in real time
kubectl logs -f <pod-name>

# Last 50 lines only
kubectl logs <pod-name> --tail=50

# Get a shell inside a running pod
kubectl exec -it <pod-name> -- /bin/bash
# or, if bash isn't available:
kubectl exec -it <pod-name> -- /bin/sh

# Run a single command without interactive shell
kubectl exec <pod-name> -- ls /app

# Copy a file from pod to local machine
kubectl cp <pod-name>:/path/to/file ./local-file

# Copy a file from local to pod
kubectl cp ./local-file <pod-name>:/path/to/file
```

### Deleting Pods
```bash
# Delete a pod
kubectl delete pod <pod-name>

# Force delete (skips graceful shutdown)
kubectl delete pod <pod-name> --force

# Delete from a file
kubectl delete -f pod-basic.yaml
```

---

## Working with Deployments

```bash
# Create a deployment
kubectl create deployment myapp --image=nginx:alpine --replicas=3

# List deployments
kubectl get deployments
kubectl get deploy          # shortened alias

# Detailed deployment info
kubectl describe deployment myapp

# Scale a deployment
kubectl scale deployment myapp --replicas=5

# Update the container image (triggers rolling update)
kubectl set image deployment/myapp nginx=nginx:1.25

# Watch the rolling update progress
kubectl rollout status deployment/myapp

# Check rollout history
kubectl rollout history deployment/myapp

# Undo the last rollout
kubectl rollout undo deployment/myapp

# Undo to a specific revision
kubectl rollout undo deployment/myapp --to-revision=2

# Pause a rolling update
kubectl rollout pause deployment/myapp

# Resume a paused rollout
kubectl rollout resume deployment/myapp

# Delete a deployment (and all its pods)
kubectl delete deployment myapp
```

---

## Working with ReplicaSets

```bash
# List ReplicaSets
kubectl get replicasets
kubectl get rs               # shortened alias

# Describe a ReplicaSet
kubectl describe rs <name>

# Manually scale (prefer scaling via the Deployment instead)
kubectl scale rs <name> --replicas=3
```

---

## Working with Services

```bash
# List services
kubectl get services
kubectl get svc              # shortened alias

# Describe a service (shows endpoints / pod IPs behind it)
kubectl describe service <name>

# Expose a deployment as a service
kubectl expose deployment myapp --port=80 --type=NodePort
kubectl expose deployment myapp --port=80 --type=LoadBalancer
kubectl expose deployment myapp --port=80 --type=ClusterIP

# Port-forward a service to localhost (for local testing)
kubectl port-forward service/myapp 8080:80
# Now open: http://localhost:8080
```

---

## Working with Namespaces

```bash
# List all namespaces
kubectl get namespaces
kubectl get ns               # shortened alias

# Create a namespace
kubectl create namespace staging

# Run commands in a specific namespace
kubectl get pods -n staging
kubectl get pods --namespace=staging

# Apply a manifest into a namespace
kubectl apply -f pod.yaml -n staging

# Delete a namespace (DELETES EVERYTHING in it)
kubectl delete namespace staging
```

---

## Applying and Managing YAML

```bash
# Apply a manifest (create or update — idempotent)
kubectl apply -f myfile.yaml

# Apply all YAMLs in a directory
kubectl apply -f manifests/

# Dry run — see what WOULD change without applying
kubectl apply -f myfile.yaml --dry-run=client

# Validate YAML before applying
kubectl apply -f myfile.yaml --dry-run=server

# Delete resources from a file
kubectl delete -f myfile.yaml

# See the diff between live state and file
kubectl diff -f myfile.yaml

# Get the YAML of a live resource
kubectl get deployment myapp -o yaml

# Output in JSON instead
kubectl get deployment myapp -o json
```

---

## Labels and Selectors

```bash
# Add a label to a resource
kubectl label pod mypod environment=production

# Remove a label
kubectl label pod mypod environment-

# Filter resources by label
kubectl get pods -l environment=production
kubectl get pods -l "app=nginx,tier=frontend"

# Label a node (for node-selector based scheduling)
kubectl label node <node-name> disk=ssd
```

---

## Debugging Cluster Issues

```bash
# Check node conditions (memory pressure, disk pressure)
kubectl describe node <node-name> | grep -A5 Conditions

# Check events across the cluster
kubectl get events --sort-by='.metadata.creationTimestamp'

# Check events in a specific namespace
kubectl get events -n kube-system

# Check API server health
kubectl get componentstatuses

# Run a temporary debug pod
kubectl run debug --image=busybox --restart=Never --rm -it -- /bin/sh

# Check resource usage (metrics-server must be installed)
kubectl top nodes
kubectl top pods
```

---

## Quick Reference: Resource Short Names

| Resource | Short Name |
|---|---|
| pods | po |
| services | svc |
| deployments | deploy |
| replicasets | rs |
| namespaces | ns |
| nodes | no |
| persistentvolumes | pv |
| persistentvolumeclaims | pvc |
| configmaps | cm |
| serviceaccounts | sa |

Example: `kubectl get po` is the same as `kubectl get pods`

---

## Useful Flags

| Flag | Meaning | Example |
|---|---|---|
| `-n <ns>` | Namespace | `kubectl get pods -n kube-system` |
| `-o wide` | Extra columns | `kubectl get pods -o wide` |
| `-o yaml` | YAML output | `kubectl get pod x -o yaml` |
| `-o json` | JSON output | `kubectl get pod x -o json` |
| `--all-namespaces` / `-A` | All namespaces | `kubectl get pods -A` |
| `-w` | Watch (real-time updates) | `kubectl get pods -w` |
| `--dry-run=client` | Simulate, don't apply | `kubectl apply -f x.yaml --dry-run=client` |
| `--force` | Force delete | `kubectl delete pod x --force` |
| `-l <label>` | Label selector | `kubectl get pods -l app=nginx` |
| `--show-labels` | Show all labels | `kubectl get pods --show-labels` |

---

## 🧑‍💻 Author

*Md. Sarowar Alam*  
Lead DevOps Engineer, WPP Production  
📧 Email: sarowar@hotmail.com  
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/
