#!/usr/bin/env bash
# =============================================================================
# provision-ec2.sh
# Launch EC2 instances across public and private subnets using a named profile.
#
# Compatible : Linux  |  macOS  |  Windows Git Bash
#
# Usage
#   bash provision-ec2.sh
#
# Override any variable inline without editing the script:
#   AMI_ID=ami-0abc123 PUBLIC_COUNT=2 bash provision-ec2.sh
#
# Or export before running:
#   export AWS_PROFILE=myprofile
#   export AMI_ID=ami-0abc123
#   bash provision-ec2.sh
# =============================================================================
set -euo pipefail

# =============================================================================
#  CONFIGURATION
#  Edit the values below, or override with environment variables.
# =============================================================================

# ── AWS connection ────────────────────────────────────────────────────────────
AWS_PROFILE="${AWS_PROFILE:-sop}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

# ── Required ──────────────────────────────────────────────────────────────────
AMI_ID="${AMI_ID:-}"                           # e.g. ami-0522ab6e1ddcc7055
VPC_ID="${VPC_ID:-}"                           # e.g. vpc-0a1b2c3d4e5f67890
PUBLIC_SUBNET_ID="${PUBLIC_SUBNET_ID:-}"       # Subnet that assigns public IPs
PRIVATE_SUBNET_ID="${PRIVATE_SUBNET_ID:-}"     # Subnet without public-IP assignment
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"     # Applied to all instances

# ── Optional ──────────────────────────────────────────────────────────────────
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"           # e.g. t3.micro, m5.large
KEY_NAME="${KEY_NAME:-k8s-lab-key}"                   # EC2 key pair (must exist in the region)
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-}"    # IAM instance profile — leave empty to skip
NAME_PREFIX="${NAME_PREFIX:-node}"                    # Tags: node-public-1, node-private-1, etc.

# ── Instance counts ───────────────────────────────────────────────────────────
PUBLIC_COUNT="${PUBLIC_COUNT:-1}"    # Instances in the public subnet  (receive public IPs)
PRIVATE_COUNT="${PRIVATE_COUNT:-2}"  # Instances in the private subnet (private IPs only)

# ── Output ────────────────────────────────────────────────────────────────────
STATE_FILE="${STATE_FILE:-./cluster-state.env}"   # Written after provisioning completes

# =============================================================================
#  COLOURS  (disabled automatically when stdout is not a TTY)
# =============================================================================
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

step() { echo -e "${BLUE}--${RESET} $*"; }
ok()   { echo -e "   ${GREEN}[OK]${RESET}   $*"; }
warn() { echo -e "   ${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# =============================================================================
#  VALIDATION
# =============================================================================
validate() {
  step "Validating prerequisites and configuration..."

  command -v aws >/dev/null 2>&1 \
    || fail "aws CLI not installed. See: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"

  aws configure list --profile "${AWS_PROFILE}" >/dev/null 2>&1 \
    || fail "AWS profile '${AWS_PROFILE}' not found. Run: aws configure --profile ${AWS_PROFILE}"

  # Verify the profile can actually authenticate
  aws sts get-caller-identity --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
      --output text --query "Account" >/dev/null 2>&1 \
    || fail "AWS credentials for profile '${AWS_PROFILE}' are invalid or expired."

  local missing=0
  for var in AMI_ID VPC_ID PUBLIC_SUBNET_ID PRIVATE_SUBNET_ID SECURITY_GROUP_ID; do
    if [[ -z "${!var}" ]]; then
      warn "${var} is not set"
      missing=1
    fi
  done
  [[ "${missing}" -eq 1 ]] \
    && fail "Set the missing required values above (edit the script or export env vars) and re-run."

  # Validate counts are positive integers
  [[ "${PUBLIC_COUNT}"  =~ ^[1-9][0-9]*$ ]] \
    || fail "PUBLIC_COUNT must be a positive integer (got: '${PUBLIC_COUNT}')"
  [[ "${PRIVATE_COUNT}" =~ ^[1-9][0-9]*$ ]] \
    || fail "PRIVATE_COUNT must be a positive integer (got: '${PRIVATE_COUNT}')"

  ok "AWS CLI present"
  ok "Profile '${AWS_PROFILE}' authenticated"
  ok "All required values present"
}

# =============================================================================
#  EC2 HELPERS
# =============================================================================

# launch_instance <name> <subnet-id> <associate-public-ip: true|false>
# Prints the new instance ID to stdout.
launch_instance() {
  local name="$1"
  local subnet="$2"
  local want_public="$3"

  # Build command as an array for safe, readable argument passing
  local cmd=(
    aws ec2 run-instances
      --profile            "${AWS_PROFILE}"
      --region             "${AWS_REGION}"
      --image-id           "${AMI_ID}"
      --instance-type      "${INSTANCE_TYPE}"
      --key-name           "${KEY_NAME}"
      --subnet-id          "${subnet}"
      --security-group-ids "${SECURITY_GROUP_ID}"
      --count              1
      --tag-specifications
        "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=CreatedBy,Value=provision-ec2.sh},{Key=Prefix,Value=${NAME_PREFIX}}]"
        "ResourceType=volume,Tags=[{Key=Name,Value=${name}-vol},{Key=CreatedBy,Value=provision-ec2.sh}]"
      --query  "Instances[0].InstanceId"
      --output text
  )

  # Public IP flag — mutually exclusive
  if [[ "${want_public}" == "true" ]]; then
    cmd+=(--associate-public-ip-address)
  else
    cmd+=(--no-associate-public-ip-address)
  fi

  # IAM instance profile — only added when set
  if [[ -n "${INSTANCE_PROFILE_NAME}" ]]; then
    cmd+=(--iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}")
  fi

  "${cmd[@]}"
}

# get_ip <instance-id> <PublicIpAddress|PrivateIpAddress>
get_ip() {
  aws ec2 describe-instances \
    --profile      "${AWS_PROFILE}" \
    --region       "${AWS_REGION}" \
    --instance-ids "$1" \
    --query        "Reservations[0].Instances[0].$2" \
    --output       text
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
  echo ""
  echo -e "${CYAN}${BOLD}+==============================================================+${RESET}"
  echo -e "${CYAN}${BOLD}|        EC2 Provisioner — Public + Private Subnets            |${RESET}"
  echo -e "${CYAN}${BOLD}+==============================================================+${RESET}"
  echo ""
  echo -e "  Profile        : ${YELLOW}${AWS_PROFILE}${RESET}   Region: ${YELLOW}${AWS_REGION}${RESET}"
  echo -e "  AMI            : ${YELLOW}${AMI_ID:-<not set>}${RESET}"
  echo -e "  Instance type  : ${YELLOW}${INSTANCE_TYPE}${RESET}   Key pair: ${YELLOW}${KEY_NAME}${RESET}"
  echo -e "  VPC            : ${YELLOW}${VPC_ID:-<not set>}${RESET}"
  echo -e "  Security group : ${YELLOW}${SECURITY_GROUP_ID:-<not set>}${RESET}"
  [[ -n "${INSTANCE_PROFILE_NAME}" ]] && \
    echo -e "  IAM profile    : ${YELLOW}${INSTANCE_PROFILE_NAME}${RESET}"
  echo -e "  Public subnet  : ${YELLOW}${PUBLIC_SUBNET_ID:-<not set>}${RESET}   x${PUBLIC_COUNT} instance(s)"
  echo -e "  Private subnet : ${YELLOW}${PRIVATE_SUBNET_ID:-<not set>}${RESET}   x${PRIVATE_COUNT} instance(s)"
  echo ""

  validate

  # ── Launch public subnet instances ─────────────────────────────────────────
  step "Launching ${PUBLIC_COUNT} instance(s) in public subnet (${PUBLIC_SUBNET_ID})..."
  PUBLIC_IDS=()
  for i in $(seq 1 "${PUBLIC_COUNT}"); do
    inst_name="${NAME_PREFIX}-public-${i}"
    iid=$(launch_instance "${inst_name}" "${PUBLIC_SUBNET_ID}" "true")
    PUBLIC_IDS+=("${iid}")
    ok "${inst_name}  ->  ${iid}"
  done

  # ── Launch private subnet instances ────────────────────────────────────────
  step "Launching ${PRIVATE_COUNT} instance(s) in private subnet (${PRIVATE_SUBNET_ID})..."
  PRIVATE_IDS=()
  for i in $(seq 1 "${PRIVATE_COUNT}"); do
    inst_name="${NAME_PREFIX}-private-${i}"
    iid=$(launch_instance "${inst_name}" "${PRIVATE_SUBNET_ID}" "false")
    PRIVATE_IDS+=("${iid}")
    ok "${inst_name}  ->  ${iid}"
  done

  # ── Wait for all instances to reach 'running' ───────────────────────────────
  ALL_IDS=("${PUBLIC_IDS[@]}" "${PRIVATE_IDS[@]}")
  step "Waiting for ${#ALL_IDS[@]} instance(s) to reach 'running' state (up to 5 min)..."
  aws ec2 wait instance-running \
    --profile      "${AWS_PROFILE}" \
    --region       "${AWS_REGION}" \
    --instance-ids "${ALL_IDS[@]}"
  ok "All instances are running"

  # ── Collect IPs ─────────────────────────────────────────────────────────────
  step "Fetching IP addresses..."

  PUBLIC_PUB_IPS=()
  PUBLIC_PRIV_IPS=()
  for iid in "${PUBLIC_IDS[@]}"; do
    PUBLIC_PUB_IPS+=("$(get_ip "${iid}" "PublicIpAddress")")
    PUBLIC_PRIV_IPS+=("$(get_ip "${iid}" "PrivateIpAddress")")
  done

  PRIVATE_PRIV_IPS=()
  for iid in "${PRIVATE_IDS[@]}"; do
    PRIVATE_PRIV_IPS+=("$(get_ip "${iid}" "PrivateIpAddress")")
  done

  # ── Write state file ─────────────────────────────────────────────────────────
  step "Writing state to ${STATE_FILE}..."
  {
    echo "# Generated by provision-ec2.sh"
    echo "# Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    echo "AWS_PROFILE=${AWS_PROFILE}"
    echo "AWS_REGION=${AWS_REGION}"
    echo ""
    echo "# Public subnet instances"
    for i in "${!PUBLIC_IDS[@]}"; do
      idx=$((i + 1))
      echo "PUBLIC_${idx}_INSTANCE_ID=${PUBLIC_IDS[$i]}"
      echo "PUBLIC_${idx}_PUBLIC_IP=${PUBLIC_PUB_IPS[$i]}"
      echo "PUBLIC_${idx}_PRIVATE_IP=${PUBLIC_PRIV_IPS[$i]}"
    done
    echo ""
    echo "# Private subnet instances"
    for i in "${!PRIVATE_IDS[@]}"; do
      idx=$((i + 1))
      echo "PRIVATE_${idx}_INSTANCE_ID=${PRIVATE_IDS[$i]}"
      echo "PRIVATE_${idx}_PRIVATE_IP=${PRIVATE_PRIV_IPS[$i]}"
    done
  } > "${STATE_FILE}"
  ok "Saved to ${STATE_FILE}"

  # ── Print summary ─────────────────────────────────────────────────────────────
  echo ""
  echo -e "${GREEN}${BOLD}+==============================================================+${RESET}"
  echo -e "${GREEN}${BOLD}|                   PROVISIONING COMPLETE                      |${RESET}"
  echo -e "${GREEN}${BOLD}+==============================================================+${RESET}"
  echo ""

  echo -e "${CYAN}Public instances (public + private IPs):${RESET}"
  for i in "${!PUBLIC_IDS[@]}"; do
    idx=$((i + 1))
    printf "  %-22s  %-21s  pub:%-16s  priv:%s\n" \
      "${NAME_PREFIX}-public-${idx}" \
      "${PUBLIC_IDS[$i]}" \
      "${PUBLIC_PUB_IPS[$i]}" \
      "${PUBLIC_PRIV_IPS[$i]}"
  done

  echo ""
  echo -e "${CYAN}Private instances (private IP only):${RESET}"
  for i in "${!PRIVATE_IDS[@]}"; do
    idx=$((i + 1))
    printf "  %-22s  %-21s  priv:%s\n" \
      "${NAME_PREFIX}-private-${idx}" \
      "${PRIVATE_IDS[$i]}" \
      "${PRIVATE_PRIV_IPS[$i]}"
  done

  echo ""
  echo -e "  State file  :  ${YELLOW}${STATE_FILE}${RESET}"
  echo -e "  Load IPs    :  ${CYAN}source ${STATE_FILE}${RESET}"
  echo -e "  SSH example :  ${CYAN}ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@<PUBLIC_IP>${RESET}"
  echo ""
}

main "$@"
