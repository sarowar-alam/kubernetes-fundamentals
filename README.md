# Kubernetes Fundamentals
### DevOps Track

---

## Overview

This repository provides a production-oriented introduction to Kubernetes — covering core architecture, cluster setup on AWS, workload management, and common operational patterns.

**Topics covered:**
- Kubernetes architecture and core components
- Self-managed cluster setup using **kubeadm** on AWS EC2
- Managed cluster setup using **AWS EKS**
- Workload management with `kubectl`
- Pods, ReplicaSets, Deployments, Services, and Namespaces
- Debugging and troubleshooting

---

## Prerequisites

| Skill | Level Required |
|---|---|
| Linux command line | Basic (ls, cd, ssh, sudo, vim/nano) |
| Docker / containers | Basic (run an image, understand images) |
| AWS Console / CLI | Basic (launch EC2, understand IAM) |
| Networking | Basic (IP, ports, TCP/UDP) |

---

## Content Roadmap

| # | Topic | Type | Est. Time |
|---|---|---|---|
| 1 | Introduction to Kubernetes & Container Orchestration | Reference + Demo | 45 min |
| 2 | Kubernetes Architecture (Master + Worker) | Reference + Diagrams | 60 min |
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
│   └── instructor-notes.md            ← Excluded from this repo (see .gitignore)
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
└── kubectl-cheatsheet.md              ← Reference: all common commands, copy-paste ready
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

## How to Use This Repository

### Option A — Guided Lab
1. Provision the cluster: `scripts/provision-cluster.sh`
2. SSH into each node and follow the lab guides in order
3. Work through each `docs/` file and `labs/` folder sequentially
4. Apply manifests from the `manifests/` directory

### Option B — Self-Guided
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
| **Total per run** | | | **~$0.55** |

> Run `scripts/teardown-cluster.sh` after each use to avoid ongoing charges.
