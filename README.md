# Kubernetes Fundamentals — Module 11
### Ostad | Batch-09 | DevOps Track

---

## Course Overview

This module gives you a production-grade introduction to Kubernetes — from understanding what it is, to setting up real clusters on AWS, to deploying and managing applications with confidence.

By the end of this module you will:
- Understand Kubernetes architecture and why it exists
- Set up a self-managed cluster using **kubeadm** on AWS EC2
- Set up a managed cluster using **AWS EKS**
- Use `kubectl` to manage workloads
- Deploy Pods, ReplicaSets, Deployments, Services, and Namespaces
- Debug and troubleshoot common issues

---

## Prerequisites

| Skill | Level Required |
|---|---|
| Linux command line | Basic (ls, cd, ssh, sudo, vim/nano) |
| Docker / containers | Basic (run an image, understand images) |
| AWS Console / CLI | Basic (launch EC2, understand IAM) |
| Networking | Basic (IP, ports, TCP/UDP) |

---

## Module Roadmap

| Session | Topic | Type | Duration |
|---|---|---|---|
| 1 | Introduction to Kubernetes & Container Orchestration | Theory + Demo | 45 min |
| 2 | Kubernetes Architecture (Master + Worker) | Theory + Diagrams | 60 min |
| 3 | **Lab 1:** Cluster with kubeadm on AWS | Hands-On | 90 min |
| 4 | kubectl CLI + kubeconfig | Hands-On | 30 min |
| 5 | Pods, ReplicaSets, Deployments | Hands-On | 60 min |
| 6 | Services + Namespaces | Hands-On | 45 min |
| 7 | **Lab 2:** AWS EKS Cluster with eksctl | Hands-On | 60 min |
| | **Total** | | ~6.5 hours |

---

## Repository Structure

```
kubernetes-fundamentals/
│
├── README.md                          ← You are here
│
├── docs/
│   ├── 01-introduction.md             ← What is K8s, Why K8s, Compose vs K8s
│   ├── 02-architecture.md             ← Control plane, worker nodes, all components
│   └── instructor-notes.md            ← Teaching tips, analogies, common mistakes
│
├── scripts/
│   ├── provision-cluster.sh           ← AWS CLI: create 3 EC2s + security groups
│   ├── teardown-cluster.sh            ← AWS CLI: terminate everything safely
│   └── install-kubeadm-node.sh        ← Runs on ALL nodes before kubeadm
│
├── labs/
│   ├── lab-01-kubeadm/
│   │   ├── README.md                  ← Full written lab guide (start here)
│   │   ├── master-init.sh             ← kubeadm init + Calico CNI
│   │   └── worker-join.sh             ← kubeadm join template
│   └── lab-02-eks/
│       ├── README.md                  ← EKS setup guide with explanations
│       ├── cluster-config.yaml        ← eksctl ClusterConfig (annotated)
│       └── install-eksctl.sh          ← Install eksctl on your machine
│
├── manifests/
│   ├── 01-pod/                        ← pod-basic.yaml, pod-debug.yaml
│   ├── 02-replicaset/                 ← replicaset.yaml
│   ├── 03-deployment/                 ← deployment.yaml + rollback-steps.md
│   ├── 04-service/                    ← clusterip, nodeport, loadbalancer
│   └── 05-namespace/                  ← namespace.yaml
│
└── kubectl-cheatsheet.md              ← All commands you need, copy-paste ready
```

---

## AWS Setup Used in This Module

| Resource | Value |
|---|---|
| Region | `ap-south-1` (Mumbai) |
| AWS Profile | `sop` |
| Instance Type | `t3.medium` (2 vCPU / 4 GB RAM) |
| OS | Ubuntu 22.04 LTS |
| Cluster Nodes | 1 Master + 2 Workers |

---

## How to Use This Module

### Option A — Follow Along Live (Recommended)
1. Instructor provisions the cluster using `scripts/provision-cluster.sh`
2. Students SSH into the worker nodes
3. Instructor walks through each `docs/` file and `labs/` folder in order
4. Students apply manifests from `manifests/` directory

### Option B — Self Study
1. Read `docs/01-introduction.md` → `docs/02-architecture.md`
2. Follow `labs/lab-01-kubeadm/README.md` end-to-end
3. Apply each manifest, verify, then break and fix it
4. Follow `labs/lab-02-eks/README.md` for EKS

---

## Cost Estimate (AWS ap-south-1)

| Resource | Price/hr | Hours | Estimate |
|---|---|---|---|
| 3x t3.medium EC2 | ~$0.0416/hr each | 3 hrs | ~$0.37 |
| EKS Cluster | $0.10/hr | 1 hr | $0.10 |
| EKS 2x t3.medium Nodes | ~$0.0416/hr each | 1 hr | ~$0.08 |
| **Total per session** | | | **~$0.55** |

> Always run `scripts/teardown-cluster.sh` after each session to avoid charges.
