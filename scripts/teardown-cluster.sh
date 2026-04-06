#!/usr/bin/env bash
# =============================================================================
# teardown-cluster.sh
# Destroys all AWS resources created by provision-cluster.sh
#
# Resources destroyed (in safe order):
#   1. EC2 instances (master + workers) — terminated
#   2. Security Group
#   3. Internet Gateway (detach then delete)
#   4. Subnet
#   5. VPC
#
# Usage:
#   chmod +x teardown-cluster.sh
#   ./teardown-cluster.sh
#
# Requires: cluster-state.env written by provision-cluster.sh
# =============================================================================

set -euo pipefail

STATE_FILE="cluster-state.env"

# ---------------------------------------------------------------------------
# Load state from provision script
# ---------------------------------------------------------------------------
if [[ ! -f "${STATE_FILE}" ]]; then
  echo "[ERROR] ${STATE_FILE} not found."
  echo "        This file is created by provision-cluster.sh."
  echo "        Cannot safely destroy resources without it."
  exit 1
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

echo ""
echo "====================================================================="
echo "  TEARDOWN: ${CLUSTER_NAME}"
echo "  Region  : ${REGION}"
echo "  Profile : ${AWS_PROFILE}"
echo "====================================================================="
echo ""
echo "  The following resources will be PERMANENTLY DELETED:"
echo "    EC2 Instances : ${MASTER_ID}  ${WORKER1_ID}  ${WORKER2_ID}"
echo "    Security Group: ${SG_ID}"
echo "    Subnet        : ${SUBNET_ID}"
echo "    Internet GW   : ${IGW_ID}"
echo "    VPC           : ${VPC_ID}"
echo ""
read -rp "  Type 'yes' to confirm teardown: " CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
  echo "[ABORT] Teardown cancelled."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Terminate EC2 Instances
# ---------------------------------------------------------------------------
echo ""
echo "[INFO] Terminating EC2 instances..."
aws ec2 terminate-instances \
  --profile      "${AWS_PROFILE}" \
  --region       "${REGION}" \
  --instance-ids "${MASTER_ID}" "${WORKER1_ID}" "${WORKER2_ID}" \
  --output text > /dev/null

echo "[INFO] Waiting for instances to terminate (this takes ~60 seconds)..."
aws ec2 wait instance-terminated \
  --profile      "${AWS_PROFILE}" \
  --region       "${REGION}" \
  --instance-ids "${MASTER_ID}" "${WORKER1_ID}" "${WORKER2_ID}"

echo "[INFO] All instances terminated."

# ---------------------------------------------------------------------------
# 2. Delete Security Group
# ---------------------------------------------------------------------------
echo "[INFO] Deleting Security Group ${SG_ID}..."
aws ec2 delete-security-group \
  --profile  "${AWS_PROFILE}" \
  --region   "${REGION}" \
  --group-id "${SG_ID}"
echo "[INFO] Security Group deleted."

# ---------------------------------------------------------------------------
# 3. Detach and Delete Internet Gateway
# ---------------------------------------------------------------------------
echo "[INFO] Detaching Internet Gateway ${IGW_ID}..."
aws ec2 detach-internet-gateway \
  --profile             "${AWS_PROFILE}" \
  --region              "${REGION}" \
  --internet-gateway-id "${IGW_ID}" \
  --vpc-id              "${VPC_ID}"

echo "[INFO] Deleting Internet Gateway ${IGW_ID}..."
aws ec2 delete-internet-gateway \
  --profile             "${AWS_PROFILE}" \
  --region              "${REGION}" \
  --internet-gateway-id "${IGW_ID}"
echo "[INFO] Internet Gateway deleted."

# ---------------------------------------------------------------------------
# 4. Delete Subnet
# ---------------------------------------------------------------------------
echo "[INFO] Deleting Subnet ${SUBNET_ID}..."
aws ec2 delete-subnet \
  --profile   "${AWS_PROFILE}" \
  --region    "${REGION}" \
  --subnet-id "${SUBNET_ID}"
echo "[INFO] Subnet deleted."

# ---------------------------------------------------------------------------
# 5. Delete VPC
# ---------------------------------------------------------------------------
echo "[INFO] Deleting VPC ${VPC_ID}..."
aws ec2 delete-vpc \
  --profile "${AWS_PROFILE}" \
  --region  "${REGION}" \
  --vpc-id  "${VPC_ID}"
echo "[INFO] VPC deleted."

# ---------------------------------------------------------------------------
# 6. Rename state file (don't delete it, keep as audit log)
# ---------------------------------------------------------------------------
mv "${STATE_FILE}" "${STATE_FILE}.destroyed"
echo "[INFO] State file archived as ${STATE_FILE}.destroyed"

echo ""
echo "====================================================================="
echo "  TEARDOWN COMPLETE — All resources destroyed."
echo "  No further AWS charges will accrue for this cluster."
echo "====================================================================="
