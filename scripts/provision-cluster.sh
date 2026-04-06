#!/usr/bin/env bash
# =============================================================================
# provision-cluster.sh
# Provisions a 3-node Kubernetes lab cluster on AWS (ap-south-1 / Mumbai)
#
# Resources created:
#   - 1x VPC                    (CIDR: 10.0.0.0/16)
#   - 1x Public Subnet           (CIDR: 10.0.1.0/24)
#   - 1x Internet Gateway        (attached to VPC)
#   - 1x Route Table             (0.0.0.0/0 → IGW)
#   - 1x Security Group          (k8s-cluster-sg)
#   - 3x EC2 t3.medium instances (1 master + 2 workers, Ubuntu 22.04)
#
# Output:
#   - cluster-state.env          (stores IDs for teardown)
#   - SSH instructions printed to terminal
#
# Usage:
#   chmod +x provision-cluster.sh
#   ./provision-cluster.sh
#
# Requirements:
#   - AWS CLI v2 installed
#   - AWS named profile "sop" configured: aws configure --profile sop
#   - The profile must have permissions: EC2 full access
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — change these if needed
# ---------------------------------------------------------------------------
AWS_PROFILE="sop"
REGION="ap-south-1"
INSTANCE_TYPE="t3.medium"
KEY_NAME="k8s-lab-key"            # Name of an existing EC2 key pair
CLUSTER_NAME="k8s-lab-cluster"
STATE_FILE="cluster-state.env"    # Written here; used by teardown-cluster.sh

# Ubuntu 22.04 LTS AMI (dynamically fetched — never goes stale)
echo "[INFO] Fetching latest Ubuntu 22.04 LTS AMI for ${REGION}..."
AMI_ID=$(aws ec2 describe-images \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --owners  099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)

echo "[INFO] Using AMI: ${AMI_ID}"

# ---------------------------------------------------------------------------
# 1. Create VPC
# ---------------------------------------------------------------------------
echo "[INFO] Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --cidr-block 10.0.0.0/16 \
  --query "Vpc.VpcId" \
  --output text)

aws ec2 create-tags \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --resources "${VPC_ID}" \
  --tags Key=Name,Value="${CLUSTER_NAME}-vpc"

# Enable DNS hostnames — required for EC2 hostnames used in kubeadm
aws ec2 modify-vpc-attribute \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --vpc-id  "${VPC_ID}" \
  --enable-dns-hostnames

echo "[INFO] VPC created: ${VPC_ID}"

# ---------------------------------------------------------------------------
# 2. Create Public Subnet
# ---------------------------------------------------------------------------
echo "[INFO] Creating public subnet..."
SUBNET_ID=$(aws ec2 create-subnet \
  --profile            "${AWS_PROFILE}" \
  --region             "${REGION}" \
  --vpc-id             "${VPC_ID}" \
  --cidr-block         10.0.1.0/24 \
  --availability-zone  "${REGION}a" \
  --query "Subnet.SubnetId" \
  --output text)

# Auto-assign public IPs so we can SSH without Elastic IPs
aws ec2 modify-subnet-attribute \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --subnet-id "${SUBNET_ID}" \
  --map-public-ip-on-launch

aws ec2 create-tags \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --resources "${SUBNET_ID}" \
  --tags Key=Name,Value="${CLUSTER_NAME}-public-subnet"

echo "[INFO] Subnet created: ${SUBNET_ID}"

# ---------------------------------------------------------------------------
# 3. Internet Gateway
# ---------------------------------------------------------------------------
echo "[INFO] Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --query "InternetGateway.InternetGatewayId" \
  --output text)

aws ec2 attach-internet-gateway \
  --profile              "${AWS_PROFILE}" \
  --region               "${REGION}" \
  --internet-gateway-id  "${IGW_ID}" \
  --vpc-id               "${VPC_ID}"

aws ec2 create-tags \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --resources "${IGW_ID}" \
  --tags Key=Name,Value="${CLUSTER_NAME}-igw"

echo "[INFO] Internet Gateway created and attached: ${IGW_ID}"

# ---------------------------------------------------------------------------
# 4. Route Table
# ---------------------------------------------------------------------------
echo "[INFO] Configuring route table..."
RTB_ID=$(aws ec2 describe-route-tables \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

aws ec2 create-route \
  --profile              "${AWS_PROFILE}" \
  --region               "${REGION}" \
  --route-table-id       "${RTB_ID}" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id           "${IGW_ID}"

aws ec2 associate-route-table \
  --profile        "${AWS_PROFILE}" \
  --region         "${REGION}" \
  --route-table-id "${RTB_ID}" \
  --subnet-id      "${SUBNET_ID}"

echo "[INFO] Route table configured: ${RTB_ID}"

# ---------------------------------------------------------------------------
# 5. Security Group
# ---------------------------------------------------------------------------
echo "[INFO] Creating Security Group..."
SG_ID=$(aws ec2 create-security-group \
  --profile    "${AWS_PROFILE}" \
  --region     "${REGION}" \
  --group-name "${CLUSTER_NAME}-sg" \
  --description "Kubernetes cluster security group" \
  --vpc-id     "${VPC_ID}" \
  --query "GroupId" \
  --output text)

aws ec2 create-tags \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --resources "${SG_ID}" \
  --tags Key=Name,Value="${CLUSTER_NAME}-sg"

# --- SSH (for instructor access) ---
aws ec2 authorize-security-group-ingress \
  --profile   "${AWS_PROFILE}" \
  --region    "${REGION}" \
  --group-id  "${SG_ID}" \
  --protocol  tcp --port 22 --cidr 0.0.0.0/0

# --- Kubernetes API Server (kubectl from instructor machine) ---
aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp --port 6443 --cidr 0.0.0.0/0

# --- etcd (master ↔ master, if multi-master in future) ---
aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp --port 2379 --cidr 10.0.0.0/16

aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp --port 2380 --cidr 10.0.0.0/16

# --- kubelet API (worker ↔ master) ---
aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp --port 10250 --cidr 10.0.0.0/16

# --- kube-scheduler + controller-manager (master internal) ---
aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp --port 10251 --cidr 10.0.0.0/16

aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp --port 10252 --cidr 10.0.0.0/16

# --- NodePort Services (for students to test apps in browser) ---
aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp --port 30000 --to-port 32767 --cidr 0.0.0.0/0

# --- All internal traffic between nodes (for pod networking / Calico) ---
aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol all --port -1 --source-group "${SG_ID}"

# --- ICMP (ping between nodes) ---
aws ec2 authorize-security-group-ingress \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol icmp --port -1 --cidr 10.0.0.0/16

echo "[INFO] Security Group created: ${SG_ID}"

# ---------------------------------------------------------------------------
# 6. Launch EC2 Instances
# ---------------------------------------------------------------------------

# User data script: sets hostname and installs nothing (kubeadm script runs separately)
USERDATA_MASTER=$(cat <<'USERDATA'
#!/bin/bash
hostnamectl set-hostname k8s-master
echo "k8s-master" > /etc/hostname
USERDATA
)

USERDATA_WORKER1=$(cat <<'USERDATA'
#!/bin/bash
hostnamectl set-hostname k8s-worker-1
echo "k8s-worker-1" > /etc/hostname
USERDATA
)

USERDATA_WORKER2=$(cat <<'USERDATA'
#!/bin/bash
hostnamectl set-hostname k8s-worker-2
echo "k8s-worker-2" > /etc/hostname
USERDATA
)

echo "[INFO] Launching Master Node..."
MASTER_ID=$(aws ec2 run-instances \
  --profile             "${AWS_PROFILE}" \
  --region              "${REGION}" \
  --image-id            "${AMI_ID}" \
  --instance-type       "${INSTANCE_TYPE}" \
  --key-name            "${KEY_NAME}" \
  --subnet-id           "${SUBNET_ID}" \
  --security-group-ids  "${SG_ID}" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":20,\"DeleteOnTermination\":true}}]" \
  --user-data           "${USERDATA_MASTER}" \
  --tag-specifications  "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-master},{Key=Role,Value=master},{Key=Project,Value=k8s-lab}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "[INFO] Launching Worker Node 1..."
WORKER1_ID=$(aws ec2 run-instances \
  --profile             "${AWS_PROFILE}" \
  --region              "${REGION}" \
  --image-id            "${AMI_ID}" \
  --instance-type       "${INSTANCE_TYPE}" \
  --key-name            "${KEY_NAME}" \
  --subnet-id           "${SUBNET_ID}" \
  --security-group-ids  "${SG_ID}" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":20,\"DeleteOnTermination\":true}}]" \
  --user-data           "${USERDATA_WORKER1}" \
  --tag-specifications  "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-worker-1},{Key=Role,Value=worker},{Key=Project,Value=k8s-lab}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "[INFO] Launching Worker Node 2..."
WORKER2_ID=$(aws ec2 run-instances \
  --profile             "${AWS_PROFILE}" \
  --region              "${REGION}" \
  --image-id            "${AMI_ID}" \
  --instance-type       "${INSTANCE_TYPE}" \
  --key-name            "${KEY_NAME}" \
  --subnet-id           "${SUBNET_ID}" \
  --security-group-ids  "${SG_ID}" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":20,\"DeleteOnTermination\":true}}]" \
  --user-data           "${USERDATA_WORKER2}" \
  --tag-specifications  "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-worker-2},{Key=Role,Value=worker},{Key=Project,Value=k8s-lab}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "[INFO] Instances launched. Waiting for them to be in 'running' state..."
aws ec2 wait instance-running \
  --profile    "${AWS_PROFILE}" \
  --region     "${REGION}" \
  --instance-ids "${MASTER_ID}" "${WORKER1_ID}" "${WORKER2_ID}"

echo "[INFO] All instances are running."

# ---------------------------------------------------------------------------
# 7. Get Public IPs
# ---------------------------------------------------------------------------
MASTER_IP=$(aws ec2 describe-instances \
  --profile     "${AWS_PROFILE}" \
  --region      "${REGION}" \
  --instance-ids "${MASTER_ID}" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

WORKER1_IP=$(aws ec2 describe-instances \
  --profile     "${AWS_PROFILE}" \
  --region      "${REGION}" \
  --instance-ids "${WORKER1_ID}" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

WORKER2_IP=$(aws ec2 describe-instances \
  --profile     "${AWS_PROFILE}" \
  --region      "${REGION}" \
  --instance-ids "${WORKER2_ID}" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

MASTER_PRIVATE_IP=$(aws ec2 describe-instances \
  --profile     "${AWS_PROFILE}" \
  --region      "${REGION}" \
  --instance-ids "${MASTER_ID}" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

# ---------------------------------------------------------------------------
# 8. Write State File (used by teardown-cluster.sh)
# ---------------------------------------------------------------------------
cat > "${STATE_FILE}" <<EOF
# Kubernetes Cluster State — generated by provision-cluster.sh
# DO NOT EDIT MANUALLY

CLUSTER_NAME="${CLUSTER_NAME}"
REGION="${REGION}"
AWS_PROFILE="${AWS_PROFILE}"
VPC_ID="${VPC_ID}"
SUBNET_ID="${SUBNET_ID}"
IGW_ID="${IGW_ID}"
RTB_ID="${RTB_ID}"
SG_ID="${SG_ID}"
MASTER_ID="${MASTER_ID}"
WORKER1_ID="${WORKER1_ID}"
WORKER2_ID="${WORKER2_ID}"
MASTER_IP="${MASTER_IP}"
WORKER1_IP="${WORKER1_IP}"
WORKER2_IP="${WORKER2_IP}"
MASTER_PRIVATE_IP="${MASTER_PRIVATE_IP}"
KEY_NAME="${KEY_NAME}"
EOF

echo "[INFO] State saved to ${STATE_FILE}"

# ---------------------------------------------------------------------------
# 9. Print Connection Info
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo "  CLUSTER PROVISIONING COMPLETE"
echo "====================================================================="
echo ""
echo "  Master Node:"
echo "    Instance ID : ${MASTER_ID}"
echo "    Public IP   : ${MASTER_IP}"
echo "    Private IP  : ${MASTER_PRIVATE_IP}"
echo "    SSH         : ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${MASTER_IP}"
echo ""
echo "  Worker Node 1:"
echo "    Instance ID : ${WORKER1_ID}"
echo "    Public IP   : ${WORKER1_IP}"
echo "    SSH         : ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${WORKER1_IP}"
echo ""
echo "  Worker Node 2:"
echo "    Instance ID : ${WORKER2_ID}"
echo "    Public IP   : ${WORKER2_IP}"
echo "    SSH         : ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${WORKER2_IP}"
echo ""
echo "  Next Step:"
echo "    Copy install-kubeadm-node.sh to all 3 nodes and run it."
echo "    Then follow labs/lab-01-kubeadm/README.md"
echo ""
echo "  To destroy everything when done:"
echo "    ./teardown-cluster.sh"
echo "====================================================================="
