#!/usr/bin/env bash
# =============================================================================
# provision-k8s-cluster.sh
# Fully-automated provisioning of a kubeadm Kubernetes cluster on AWS EC2.
#
# Architecture:
#   master    ->  1 instance  ->  public subnet   (public + private IP)
#   worker-1  ->  1 instance  ->  private subnet  (private IP only, via NAT/SSM)
#   worker-2  ->  1 instance  ->  private subnet  (private IP only, via NAT/SSM)
#
# Coordination strategy (zero manual steps needed):
#   1. Master runs master-init.sh via User Data.
#      master-init.sh: installs containerd + kubeadm, runs kubeadm init,
#      installs Calico CNI, and writes join command to /tmp/worker-join-command.txt
#   2. Master User Data parses that file and writes 3 values to SSM:
#        /<CLUSTER_NAME>/master-private-ip   (String)
#        /<CLUSTER_NAME>/join-token          (SecureString -- encrypted at rest)
#        /<CLUSTER_NAME>/join-hash           (String)
#   3. Worker User Data polls SSM every 30s (up to 40 min) until those params exist.
#   4. Workers fetch values then run worker-join.sh with MASTER_IP/JOIN_TOKEN/JOIN_HASH
#      as environment variables -- skipping interactive prompts.
#
# Connectivity:
#   No SSH required. Use SSM Session Manager for shell access:
#     aws ssm start-session --profile sarowar-ostad --region ap-south-1 --target <id>
#
# Usage:
#   bash provision-k8s-cluster.sh              # provision the cluster
#   bash provision-k8s-cluster.sh --teardown   # terminate instances + delete SSM params
#
# Override any variable inline without editing the file:
#   AMI_ID=ami-0abc123 CLUSTER_NAME=dev bash provision-k8s-cluster.sh
#
# IAM Instance Profile requirements (attach to INSTANCE_PROFILE_NAME):
#   AmazonSSMManagedInstanceCore   -- SSM Session Manager shell access
#   ssm:PutParameter               -- master writes join params
#   ssm:GetParameter               -- workers read join params
#   ssm:DeleteParameter            -- teardown cleanup
#
# Private subnet workers must reach the internet via one of:
#   Option A -- NAT Gateway attached to the VPC (standard, recommended)
#   Option B -- VPC Interface Endpoints:
#                 com.amazonaws.<region>.ssm
#                 com.amazonaws.<region>.ec2messages
#                 com.amazonaws.<region>.ssmmessages
#                 com.amazonaws.<region>.s3 (Gateway endpoint)
#
# Compatible: Linux | macOS | Windows Git Bash
# =============================================================================
set -euo pipefail

# =============================================================================
#  CONFIGURATION
#  All values can be overridden via environment variables.
# =============================================================================

# -- AWS connection -----------------------------------------------------------
AWS_PROFILE="${AWS_PROFILE:-sarowar-ostad}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

# -- AMI ---------------------------------------------------------------------
# Ubuntu 24.04 LTS (Noble Numbat) -- Canonical owner 099720109477
# Find the latest AMI for your region:
#   aws ec2 describe-images --owners 099720109477 \
#     --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
#     --query "sort_by(Images,&CreationDate)[-1].{ID:ImageId,Name:Name}" \
#     --output table --profile sarowar-ostad --region ap-south-1
AMI_ID="${AMI_ID:-ami-05d2d839d4f73aafb}"   # UPDATE: replace with Ubuntu 24.04 AMI for ap-south-1

# -- Network -----------------------------------------------------------------
VPC_ID="${VPC_ID:-vpc-06f7dead5c49ece64}"
PUBLIC_SUBNET_ID="${PUBLIC_SUBNET_ID:-subnet-0880772cfbeb8bb6f}"    # master node
PRIVATE_SUBNET_ID="${PRIVATE_SUBNET_ID:-subnet-054147291dc0bf764}"  # worker nodes
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-sg-097d6afb08616ba09}"      # shared for all nodes

# -- Instance ----------------------------------------------------------------
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"           # min 2 vCPU / 4 GB for K8s
KEY_NAME="${KEY_NAME:-sarowar-ostad-mumbai}"           # EC2 key pair (must exist in region)
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-SSM}" # IAM instance profile name
ROOT_VOLUME_GIB="${ROOT_VOLUME_GIB:-20}"               # gp3 root volume (GiB)

# -- Cluster identity --------------------------------------------------------
# Change CLUSTER_NAME to run multiple independent clusters in the same account.
# It namespaces EC2 Name tags and SSM Parameter Store paths.
CLUSTER_NAME="${CLUSTER_NAME:-k8s-lab}"

# -- Repository --------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/sarowar-alam/kubernetes-fundamentals.git}"
REPO_DIR="${REPO_DIR:-/opt/k8s-repo}"
SCRIPTS_REL="${SCRIPTS_REL:-labs/lab-01-kubeadm}"

# -- SSM Parameter Store paths (auto-namespaced under /<CLUSTER_NAME>/) ------
SSM_MASTER_IP="/${CLUSTER_NAME}/master-private-ip"
SSM_JOIN_TOKEN="/${CLUSTER_NAME}/join-token"   # SecureString -- encrypted at rest
SSM_JOIN_HASH="/${CLUSTER_NAME}/join-hash"

# -- State file --------------------------------------------------------------
STATE_FILE="${STATE_FILE:-./k8s-cluster-state.env}"

# =============================================================================
#  COLOURS  (auto-disabled when stdout is not a TTY)
# =============================================================================
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi
step() { echo -e "${BLUE}--${RESET} $*"; }
ok()   { echo -e "   ${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "   ${YELLOW}[WARN]${RESET}  $*"; }
fail() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
info() { echo -e "   ${CYAN}[INFO]${RESET}  $*"; }

# =============================================================================
#  VALIDATE PREREQUISITES
# =============================================================================
validate() {
  step "Validating prerequisites and configuration..."

  command -v aws >/dev/null 2>&1 \
    || fail "AWS CLI not found. Install v2: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"

  aws configure list --profile "${AWS_PROFILE}" >/dev/null 2>&1 \
    || fail "Profile '${AWS_PROFILE}' not configured. Run: aws configure --profile ${AWS_PROFILE}"

  aws sts get-caller-identity \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    --output text --query "Account" >/dev/null 2>&1 \
    || fail "Credentials for '${AWS_PROFILE}' are invalid or expired."

  for var in AMI_ID VPC_ID PUBLIC_SUBNET_ID PRIVATE_SUBNET_ID \
             SECURITY_GROUP_ID KEY_NAME INSTANCE_PROFILE_NAME; do
    [[ -z "${!var}" ]] && fail "${var} must not be empty."
  done

  ok "AWS CLI   : $(aws --version 2>&1 | head -1)"
  ok "Profile   : ${AWS_PROFILE} (authenticated)"
  ok "Variables : all required values present"
}

# =============================================================================
#  RESOLVE AMI ROOT DEVICE NAME
#  Ubuntu HVM AMIs use /dev/sda1 for the root device. Confirmed dynamically
#  so the gp3 block device mapping always targets the correct device name.
# =============================================================================
get_root_device() {
  aws ec2 describe-images \
    --profile   "${AWS_PROFILE}" \
    --region    "${AWS_REGION}" \
    --image-ids "${AMI_ID}" \
    --query     "Images[0].RootDeviceName" \
    --output    text
}

# =============================================================================
#  BUILD BLOCK DEVICE MAPPING JSON  (gp3)
# =============================================================================
build_bdm() {
  local dev="$1"
  printf '[{"DeviceName":"%s","Ebs":{"VolumeType":"gp3","VolumeSize":%d,"DeleteOnTermination":true,"Encrypted":false}}]' \
    "${dev}" "${ROOT_VOLUME_GIB}"
}
# =============================================================================
#  USER DATA -- MASTER NODE
#
#  These variables expand NOW (generation time, on your local machine):
#    ${AWS_REGION}  ${REPO_URL}  ${REPO_DIR}  ${SCRIPTS_REL}  ${CLUSTER_NAME}
#    ${SSM_MASTER_IP}  ${SSM_JOIN_TOKEN}  ${SSM_JOIN_HASH}
#
#  Variables prefixed with \${ expand LATER at runtime on the EC2 instance.
# =============================================================================
write_master_userdata() {
  local out_file="$1"
  cat > "${out_file}" <<MASTER_EOF
#!/usr/bin/env bash
# ---------------------------------------------------------------
# Master bootstrap -- EC2 User Data, runs as root via cloud-init.
# Tail logs: sudo tail -f /var/log/k8s-master-bootstrap.log
# ---------------------------------------------------------------
set -euo pipefail
exec > >(tee /var/log/k8s-master-bootstrap.log | logger -t k8s-master) 2>&1

echo "======================================================"
echo " Master Bootstrap START  \$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo " Cluster: ${CLUSTER_NAME}"
echo "======================================================"

export DEBIAN_FRONTEND=noninteractive
export AWS_DEFAULT_REGION="${AWS_REGION}"

REPO_URL="${REPO_URL}"
REPO_DIR="${REPO_DIR}"
SCRIPTS_REL="${SCRIPTS_REL}"
SSM_MASTER_IP="${SSM_MASTER_IP}"
SSM_JOIN_TOKEN="${SSM_JOIN_TOKEN}"
SSM_JOIN_HASH="${SSM_JOIN_HASH}"
NODE_NAME="${CLUSTER_NAME}-master"
export NODE_NAME

# [1/6] Wait for outbound internet -----------------------------------------
echo "[1/6] Waiting for internet access..."
slept=0
until curl -sf --max-time 5 https://archive.ubuntu.com >/dev/null 2>&1; do
  sleep 10; slept=\$((slept + 10))
  [[ \${slept} -ge 300 ]] && { echo "ERROR: No internet after 5 min. Check IGW/NAT."; exit 1; }
done
echo "  Network ready (\${slept}s wait)."

# [2/6] Install git + AWS CLI v2 -------------------------------------------
echo "[2/6] Installing git + AWS CLI v2..."
apt-get update -y -qq
apt-get install -y -qq git curl unzip
if ! aws --version 2>&1 | grep -q "aws-cli/2"; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/awscli-setup
  /tmp/awscli-setup/aws/install --update
  rm -rf /tmp/awscli-setup /tmp/awscliv2.zip
  hash -r
fi
echo "  \$(aws --version)"

# [3/6] Get private IP via IMDSv2 ------------------------------------------
echo "[3/6] Fetching private IP via IMDSv2..."
IMDS_TOKEN=\$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=\$(curl -sf -H "X-aws-ec2-metadata-token: \${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/local-ipv4")
echo "  Private IP: \${PRIVATE_IP}"

# [4/6] Clone repo ---------------------------------------------------------
echo "[4/6] Cloning repository..."
if [[ -d "\${REPO_DIR}/.git" ]]; then
  git -C "\${REPO_DIR}" pull --ff-only
  echo "  Repo already present -- pulled latest."
else
  git clone "\${REPO_URL}" "\${REPO_DIR}"
  echo "  Cloned to \${REPO_DIR}."
fi

# [5/6] Run master-init.sh -------------------------------------------------
# master-init.sh handles EVERYTHING in two phases:
#   Phase 1 -- System prep: swap off, kernel modules, sysctl,
#              containerd (systemd cgroup), kubeadm/kubelet/kubectl (K8s 1.29)
#   Phase 2 -- Cluster bootstrap: kubeadm init (pod-cidr=192.168.0.0/16),
#              kubectl config for ubuntu user, Calico CNI v3.27.0,
#              generates worker join command -> /tmp/worker-join-command.txt
echo "[5/6] Running master-init.sh -- takes ~15 min on t3.medium..."
chmod +x "\${REPO_DIR}/\${SCRIPTS_REL}/master-init.sh"
"\${REPO_DIR}/\${SCRIPTS_REL}/master-init.sh"
echo "  master-init.sh complete."

# [6/6] Parse join command + write to SSM -----------------------------------
# master-init.sh step 11 writes: /tmp/worker-join-command.txt
# Format: kubeadm join <ip:6443> --token <tkn> --discovery-token-ca-cert-hash <hash>
echo "[6/6] Writing join parameters to SSM Parameter Store..."
JOIN_CMD_FILE="/tmp/worker-join-command.txt"
[[ -f "\${JOIN_CMD_FILE}" ]] \
  || { echo "ERROR: \${JOIN_CMD_FILE} missing. master-init.sh may have failed."; exit 1; }

JOIN_CMD=\$(cat "\${JOIN_CMD_FILE}")
JOIN_TOKEN_VAL=\$(echo "\${JOIN_CMD}" | grep -oP '(?<=--token )\S+')
JOIN_HASH_VAL=\$( echo "\${JOIN_CMD}" | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')

[[ -z "\${JOIN_TOKEN_VAL}" ]] && { echo "ERROR: Could not parse --token.";                     exit 1; }
[[ -z "\${JOIN_HASH_VAL}"  ]] && { echo "ERROR: Could not parse --discovery-token-ca-cert-hash."; exit 1; }

# Write master private IP (String)
aws ssm put-parameter \
  --region "\${AWS_DEFAULT_REGION}" \
  --name "\${SSM_MASTER_IP}" --value "\${PRIVATE_IP}" \
  --type String --overwrite \
  --description "kubeadm master private IP -- ${CLUSTER_NAME}" \
  --output text >/dev/null
echo "  SSM: \${SSM_MASTER_IP} = \${PRIVATE_IP}"

# Write join token (SecureString -- AES-256 encrypted at rest)
aws ssm put-parameter \
  --region "\${AWS_DEFAULT_REGION}" \
  --name "\${SSM_JOIN_TOKEN}" --value "\${JOIN_TOKEN_VAL}" \
  --type SecureString --overwrite \
  --description "kubeadm join token -- ${CLUSTER_NAME}" \
  --output text >/dev/null
echo "  SSM: \${SSM_JOIN_TOKEN} written (SecureString)"

# Write CA cert hash (String)
aws ssm put-parameter \
  --region "\${AWS_DEFAULT_REGION}" \
  --name "\${SSM_JOIN_HASH}" --value "\${JOIN_HASH_VAL}" \
  --type String --overwrite \
  --description "kubeadm CA cert hash -- ${CLUSTER_NAME}" \
  --output text >/dev/null
echo "  SSM: \${SSM_JOIN_HASH} written"

echo ""
echo "======================================================"
echo " Master Bootstrap DONE  \$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo " Workers are polling SSM and will self-join now."
echo "======================================================"
MASTER_EOF
}
# =============================================================================
#  USER DATA -- WORKER NODE
# =============================================================================
write_worker_userdata() {
  local out_file="$1"
  local node_name="${2:-}"
  cat > "${out_file}" <<WORKER_EOF
#!/usr/bin/env bash
# ---------------------------------------------------------------
# Worker bootstrap -- EC2 User Data, runs as root via cloud-init.
# Tail logs: sudo tail -f /var/log/k8s-worker-bootstrap.log
# ---------------------------------------------------------------
set -euo pipefail
exec > >(tee /var/log/k8s-worker-bootstrap.log | logger -t k8s-worker) 2>&1

echo "======================================================"
echo " Worker Bootstrap START  \$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo " Cluster: ${CLUSTER_NAME}"
echo "======================================================"

export DEBIAN_FRONTEND=noninteractive
export AWS_DEFAULT_REGION="${AWS_REGION}"

REPO_URL="${REPO_URL}"
REPO_DIR="${REPO_DIR}"
SCRIPTS_REL="${SCRIPTS_REL}"
SSM_MASTER_IP="${SSM_MASTER_IP}"
SSM_JOIN_TOKEN="${SSM_JOIN_TOKEN}"
SSM_JOIN_HASH="${SSM_JOIN_HASH}"
NODE_NAME="${node_name}"
export NODE_NAME

# [1/4] Wait for internet (needs NAT Gateway or VPC endpoints) --------------
echo "[1/4] Waiting for outbound internet access..."
slept=0
until curl -sf --max-time 5 https://archive.ubuntu.com >/dev/null 2>&1; do
  sleep 10; slept=\$((slept + 10))
  [[ \${slept} -ge 300 ]] && {
    echo "ERROR: No internet after 5 min."
    echo "Private subnet requires a NAT Gateway or VPC Interface Endpoints."
    exit 1
  }
done
echo "  Network ready (\${slept}s wait)."

# [2/4] Install git + AWS CLI v2 -------------------------------------------
echo "[2/4] Installing git + AWS CLI v2..."
apt-get update -y -qq
apt-get install -y -qq git curl unzip
if ! aws --version 2>&1 | grep -q "aws-cli/2"; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/awscli-setup
  /tmp/awscli-setup/aws/install --update
  rm -rf /tmp/awscli-setup /tmp/awscliv2.zip
  hash -r
fi
echo "  \$(aws --version)"

# [3/4] Poll SSM for master join parameters (up to 40 min) -----------------
# Master writes these after kubeadm init + Calico install.
# On t3.medium that typically takes 15-20 min.
echo "[3/4] Polling SSM for join parameters (timeout: 40 min)..."
MAX_WAIT=2400
elapsed=0
interval=30

while true; do
  MASTER_IP=\$(aws ssm get-parameter \
    --region "\${AWS_DEFAULT_REGION}" \
    --name   "\${SSM_MASTER_IP}" \
    --query  "Parameter.Value" \
    --output text 2>/dev/null) && ssm_rc=0 || ssm_rc=\$?

  if [[ \${ssm_rc} -eq 0 && -n "\${MASTER_IP}" && "\${MASTER_IP}" != "None" ]]; then
    echo "  Master IP found: \${MASTER_IP}"
    break
  fi

  elapsed=\$((elapsed + interval))
  if [[ \${elapsed} -ge \${MAX_WAIT} ]]; then
    echo "ERROR: Timed out after \${MAX_WAIT}s. Check master logs via SSM:"
    echo "  aws ssm start-session --target <master-id>"
    echo "  sudo tail -f /var/log/k8s-master-bootstrap.log"
    exit 1
  fi
  echo "  Master not ready yet... (\${elapsed}s / \${MAX_WAIT}s) -- retry in \${interval}s"
  sleep \${interval}
done

JOIN_TOKEN=\$(aws ssm get-parameter \
  --region "\${AWS_DEFAULT_REGION}" \
  --name "\${SSM_JOIN_TOKEN}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text)

JOIN_HASH=\$(aws ssm get-parameter \
  --region "\${AWS_DEFAULT_REGION}" \
  --name "\${SSM_JOIN_HASH}" \
  --query "Parameter.Value" \
  --output text)

echo "  All join parameters retrieved."

# [4/4] Clone repo + run worker-join.sh ------------------------------------
# worker-join.sh:
#   Phase 1 -- swap off, kernel modules, sysctl, containerd, kubeadm/kubectl/kubelet
#   Phase 2 -- connectivity check to master:6443, then kubeadm join
# Passing MASTER_IP/JOIN_TOKEN/JOIN_HASH as env vars skips interactive prompts.
echo "[4/4] Cloning repo and running worker-join.sh..."
if [[ -d "\${REPO_DIR}/.git" ]]; then
  git -C "\${REPO_DIR}" pull --ff-only
else
  git clone "\${REPO_URL}" "\${REPO_DIR}"
fi

chmod +x "\${REPO_DIR}/\${SCRIPTS_REL}/worker-join.sh"

MASTER_IP="\${MASTER_IP}" \
JOIN_TOKEN="\${JOIN_TOKEN}" \
JOIN_HASH="\${JOIN_HASH}" \
NODE_NAME="\${NODE_NAME}" \
"\${REPO_DIR}/\${SCRIPTS_REL}/worker-join.sh"

echo "======================================================"
echo " Worker Bootstrap DONE  \$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "======================================================"
WORKER_EOF
}
# =============================================================================
#  LAUNCH EC2 INSTANCE
#  Args: <name> <subnet-id> <want-public: true|false> <role> <bdm-json> <ud-file>
#  Stdout: instance ID
# =============================================================================
launch_instance() {
  local name="$1" subnet="$2" want_public="$3"
  local role="$4" bdm_json="$5" userdata_file="$6"

  local public_flag
  [[ "${want_public}" == "true" ]] \
    && public_flag="--associate-public-ip-address" \
    || public_flag="--no-associate-public-ip-address"

  # On Windows/Git Bash the native aws.exe binary cannot resolve MSYS2/POSIX
  # paths like /tmp/...  It needs a Windows-style path (C:\Users\...\AppData\...).
  # cygpath -w converts:  /tmp/foo.sh  ->  C:\Users\...\AppData\Local\Temp\foo.sh
  # On Linux/macOS cygpath does not exist so we keep the original path.
  local ud_path="${userdata_file}"
  if command -v cygpath >/dev/null 2>&1; then
    ud_path=$(cygpath -w "${userdata_file}")
  fi

  aws ec2 run-instances \
    --profile              "${AWS_PROFILE}" \
    --region               "${AWS_REGION}" \
    --image-id             "${AMI_ID}" \
    --instance-type        "${INSTANCE_TYPE}" \
    --key-name             "${KEY_NAME}" \
    --subnet-id            "${subnet}" \
    --security-group-ids   "${SECURITY_GROUP_ID}" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
    --block-device-mappings "${bdm_json}" \
    --user-data            "file://${ud_path}" \
    ${public_flag} \
    --count 1 \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=ClusterName,Value=${CLUSTER_NAME}},{Key=Role,Value=${role}},{Key=CreatedBy,Value=provision-k8s-cluster.sh}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${name}-vol},{Key=ClusterName,Value=${CLUSTER_NAME}},{Key=Role,Value=${role}},{Key=CreatedBy,Value=provision-k8s-cluster.sh}]" \
    --query  "Instances[0].InstanceId" \
    --output text
}

# =============================================================================
#  GET IP ADDRESS
# =============================================================================
get_ip() {
  aws ec2 describe-instances \
    --profile      "${AWS_PROFILE}" \
    --region       "${AWS_REGION}" \
    --instance-ids "$1" \
    --query        "Reservations[0].Instances[0].$2" \
    --output       text
}

# =============================================================================
#  WAIT FOR SSM AGENT ONLINE  (~30-90s after OS boot)
# =============================================================================
wait_ssm_online() {
  local id="$1" name="$2"
  local max=300 elapsed=0 interval=15

  echo -n "   Waiting for ${name} SSM registration"
  while true; do
    local status
    status=$(aws ssm describe-instance-information \
      --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
      --filters "Key=InstanceIds,Values=${id}" \
      --query   "InstanceInformationList[0].PingStatus" \
      --output  text 2>/dev/null || echo "None")
    if [[ "${status}" == "Online" ]]; then
      echo ""; ok "${name} -> SSM Online"; return 0
    fi
    elapsed=$((elapsed + interval))
    if [[ ${elapsed} -ge ${max} ]]; then
      echo ""; warn "${name} not SSM-Online after ${max}s -- bootstrap still starting."; return 0
    fi
    echo -n "."; sleep "${interval}"
  done
}

# =============================================================================
#  WAIT FOR MASTER JOIN PARAMS IN SSM
#  Blocks this script while master-init.sh runs (~15-20 min on t3.medium).
#  Every poll cycle fetches the last 30 lines of the master bootstrap log via
#  SSM Run Command and prints them to the local console in real time.
#  Sets DETECTED_MASTER_IP when params are available.
# =============================================================================
wait_join_params() {
  local max=2400 elapsed=0 interval=30
  DETECTED_MASTER_IP=""

  step "Monitoring master bootstrap progress (up to 40 min)..."
  info "For a live interactive session (optional, separate terminal):"
  info "  aws ssm start-session --profile ${AWS_PROFILE} --region ${AWS_REGION} --target ${MASTER_INSTANCE_ID}"
  info "  sudo tail -f /var/log/k8s-master-bootstrap.log"
  echo ""

  while true; do
    # ── Check SSM FIRST -- so a slow send-command never delays detection ──────
    local val="" ssm_rc=0 ssm_err=""
    val=$(aws ssm get-parameter \
      --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
      --name    "${SSM_MASTER_IP}" \
      --query   "Parameter.Value" --output text 2>/tmp/_ssm_chk_$$) \
      || { ssm_rc=$?; ssm_err=$(cat /tmp/_ssm_chk_$$ 2>/dev/null); }
    rm -f /tmp/_ssm_chk_$$

    if [[ ${ssm_rc} -eq 0 && -n "${val}" && "${val}" != "None" ]]; then
      DETECTED_MASTER_IP="${val}"
      ok "Master join params available in SSM (master priv IP: ${val})"; return 0
    elif [[ ${ssm_rc} -ne 0 ]] && ! echo "${ssm_err}" | grep -q "ParameterNotFound"; then
      echo -e "   ${YELLOW}[SSM]${RESET} get-parameter error (rc=${ssm_rc}): ${ssm_err}"
    fi

    elapsed=$((elapsed + interval))
    if [[ ${elapsed} -ge ${max} ]]; then
      warn "Timed out (${max}s) monitoring master. Check logs via SSM."; return 1
    fi

    # ── Stream last 30 lines of bootstrap log via SSM Run Command ───────────
    local cmd_id=""
    cmd_id=$(aws ssm send-command \
      --profile       "${AWS_PROFILE}" \
      --region        "${AWS_REGION}" \
      --instance-ids  "${MASTER_INSTANCE_ID}" \
      --document-name "AWS-RunShellScript" \
      --parameters    '{"commands":["tail -n 30 /var/log/k8s-master-bootstrap.log 2>/dev/null || echo \"(log not yet available)\""]}' \
      --query         "Command.CommandId" \
      --output        text 2>/dev/null) || true

    if [[ -n "${cmd_id}" ]]; then
      # Poll up to 15s for result (master may be CPU-busy during kubeadm init)
      local ci_status="" ci_attempts=0
      while [[ "${ci_status}" != "Success" && "${ci_status}" != "Failed" \
               && ${ci_attempts} -lt 15 ]]; do
        sleep 1; ci_attempts=$((ci_attempts + 1))
        ci_status=$(aws ssm get-command-invocation \
          --profile     "${AWS_PROFILE}" \
          --region      "${AWS_REGION}" \
          --command-id  "${cmd_id}" \
          --instance-id "${MASTER_INSTANCE_ID}" \
          --query       "Status" --output text 2>/dev/null) || ci_status=""
      done

      local log_out=""
      log_out=$(aws ssm get-command-invocation \
        --profile     "${AWS_PROFILE}" \
        --region      "${AWS_REGION}" \
        --command-id  "${cmd_id}" \
        --instance-id "${MASTER_INSTANCE_ID}" \
        --query       "StandardOutputContent" \
        --output      text 2>/dev/null) || log_out=""

      if [[ -n "${log_out}" ]]; then
        echo "━━━  Master bootstrap log — ${elapsed}s elapsed  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "${log_out}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
      else
        printf "   [log] SSM Run Command queued but no output yet (normal during kubeadm init)\n\n"
      fi
    else
      printf "   [log] send-command unavailable -- master agent busy, will retry\n\n"
    fi

    printf "   Next poll in %ds...\n\n" "${interval}"
    sleep "${interval}"
  done
}
# =============================================================================
#  MAIN -- PROVISION
# =============================================================================
main() {
  echo ""
  echo -e "${CYAN}${BOLD}+============================================================+${RESET}"
  echo -e "${CYAN}${BOLD}|  K8s Cluster Provisioner -- kubeadm (1 Master + 2 Workers) |${RESET}"
  echo -e "${CYAN}${BOLD}+============================================================+${RESET}"
  echo ""
  echo -e "  Cluster        : ${YELLOW}${CLUSTER_NAME}${RESET}"
  echo -e "  AWS profile    : ${YELLOW}${AWS_PROFILE}${RESET}   Region: ${YELLOW}${AWS_REGION}${RESET}"
  echo -e "  AMI            : ${YELLOW}${AMI_ID}${RESET}"
  echo -e "  Instance type  : ${YELLOW}${INSTANCE_TYPE}${RESET}   Volume: gp3 ${ROOT_VOLUME_GIB}GiB"
  echo -e "  Key pair       : ${YELLOW}${KEY_NAME}${RESET}"
  echo -e "  IAM profile    : ${YELLOW}${INSTANCE_PROFILE_NAME}${RESET}"
  echo -e "  VPC            : ${YELLOW}${VPC_ID}${RESET}"
  echo -e "  Public subnet  : ${YELLOW}${PUBLIC_SUBNET_ID}${RESET}  -> 1 master"
  echo -e "  Private subnet : ${YELLOW}${PRIVATE_SUBNET_ID}${RESET}  -> 2 workers"
  echo -e "  Security group : ${YELLOW}${SECURITY_GROUP_ID}${RESET}"
  echo -e "  Repo           : ${YELLOW}${REPO_URL}${RESET}"
  echo -e "  SSM namespace  : ${YELLOW}/${CLUSTER_NAME}/...${RESET}"
  echo -e "  State file     : ${YELLOW}${STATE_FILE}${RESET}"
  echo ""

  validate

  # Resolve AMI root device + build gp3 block device mapping
  step "Resolving AMI root device for gp3 volume mapping..."
  ROOT_DEVICE=$(get_root_device)
  BDM_JSON=$(build_bdm "${ROOT_DEVICE}")
  ok "Root device: ${ROOT_DEVICE}  ->  gp3 ${ROOT_VOLUME_GIB}GiB  DeleteOnTermination=true"

  # Purge stale SSM join parameters from any previous cluster run.
  # Without this, workers boot and immediately read old params (e.g. a dead
  # master IP from last session) before the new master has written fresh values.
  step "Purging stale SSM join parameters..."
  for param in "${SSM_MASTER_IP}" "${SSM_JOIN_TOKEN}" "${SSM_JOIN_HASH}"; do
    if aws ssm delete-parameter \
        --profile "${AWS_PROFILE}" \
        --region  "${AWS_REGION}" \
        --name    "${param}" 2>/dev/null; then
      ok "Deleted stale param : ${param}"
    else
      ok "No stale param found: ${param}  (clean start)"
    fi
  done

  # Write user data to temp files (cleaned up after launch)
  step "Generating user data scripts..."
  MASTER_UD=$(mktemp /tmp/k8s-master-ud-XXXXX.sh)
  WORKER1_UD=$(mktemp /tmp/k8s-worker1-ud-XXXXX.sh)
  WORKER2_UD=$(mktemp /tmp/k8s-worker2-ud-XXXXX.sh)
  write_master_userdata "${MASTER_UD}"
  write_worker_userdata "${WORKER1_UD}" "${CLUSTER_NAME}-worker-1"
  write_worker_userdata "${WORKER2_UD}" "${CLUSTER_NAME}-worker-2"
  chmod 600 "${MASTER_UD}" "${WORKER1_UD}" "${WORKER2_UD}"
  ok "Master   user data : ${MASTER_UD}"
  ok "Worker-1 user data : ${WORKER1_UD}"
  ok "Worker-2 user data : ${WORKER2_UD}"

  # Launch master in public subnet
  step "Launching master node (public subnet: ${PUBLIC_SUBNET_ID})..."
  MASTER_INSTANCE_ID=$(launch_instance \
    "${CLUSTER_NAME}-master" "${PUBLIC_SUBNET_ID}" "true" "master" "${BDM_JSON}" "${MASTER_UD}")
  ok "Master    : ${MASTER_INSTANCE_ID}"

  # Launch both workers in private subnet.
  # Workers start immediately and begin polling SSM -- they will wait for master.
  step "Launching worker nodes (private subnet: ${PRIVATE_SUBNET_ID})..."
  WORKER1_INSTANCE_ID=$(launch_instance \
    "${CLUSTER_NAME}-worker-1" "${PRIVATE_SUBNET_ID}" "false" "worker" "${BDM_JSON}" "${WORKER1_UD}")
  ok "Worker-1  : ${WORKER1_INSTANCE_ID}"

  WORKER2_INSTANCE_ID=$(launch_instance \
    "${CLUSTER_NAME}-worker-2" "${PRIVATE_SUBNET_ID}" "false" "worker" "${BDM_JSON}" "${WORKER2_UD}")
  ok "Worker-2  : ${WORKER2_INSTANCE_ID}"

  # Clean up temp user data files -- no longer needed after launch
  rm -f "${MASTER_UD}" "${WORKER1_UD}" "${WORKER2_UD}"

  # Wait for all instances to reach 'running' OS state
  step "Waiting for all 3 instances to reach 'running' state..."
  aws ec2 wait instance-running \
    --profile      "${AWS_PROFILE}" \
    --region       "${AWS_REGION}" \
    --instance-ids "${MASTER_INSTANCE_ID}" "${WORKER1_INSTANCE_ID}" "${WORKER2_INSTANCE_ID}"
  ok "All 3 instances are running"

  # Collect IP addresses
  step "Fetching IP addresses..."
  MASTER_PUB_IP=$(get_ip   "${MASTER_INSTANCE_ID}"  "PublicIpAddress")
  MASTER_PRIV_IP=$(get_ip  "${MASTER_INSTANCE_ID}"  "PrivateIpAddress")
  WORKER1_PRIV_IP=$(get_ip "${WORKER1_INSTANCE_ID}" "PrivateIpAddress")
  WORKER2_PRIV_IP=$(get_ip "${WORKER2_INSTANCE_ID}" "PrivateIpAddress")
  ok "Master   : pub=${MASTER_PUB_IP}  priv=${MASTER_PRIV_IP}"
  ok "Worker-1 : priv=${WORKER1_PRIV_IP}"
  ok "Worker-2 : priv=${WORKER2_PRIV_IP}"

  # Wait for SSM agent to register on each instance
  step "Waiting for SSM agent registration on all nodes..."
  wait_ssm_online "${MASTER_INSTANCE_ID}"  "${CLUSTER_NAME}-master"
  wait_ssm_online "${WORKER1_INSTANCE_ID}" "${CLUSTER_NAME}-worker-1"
  wait_ssm_online "${WORKER2_INSTANCE_ID}" "${CLUSTER_NAME}-worker-2"

  # Persist cluster state for teardown and reference
  step "Writing cluster state to ${STATE_FILE}..."
  {
    echo "# Generated by provision-k8s-cluster.sh"
    echo "# Timestamp   : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# Cluster     : ${CLUSTER_NAME}"
    echo ""
    echo "AWS_PROFILE=${AWS_PROFILE}"
    echo "AWS_REGION=${AWS_REGION}"
    echo "CLUSTER_NAME=${CLUSTER_NAME}"
    echo ""
    echo "MASTER_INSTANCE_ID=${MASTER_INSTANCE_ID}"
    echo "MASTER_PUB_IP=${MASTER_PUB_IP}"
    echo "MASTER_PRIV_IP=${MASTER_PRIV_IP}"
    echo ""
    echo "WORKER1_INSTANCE_ID=${WORKER1_INSTANCE_ID}"
    echo "WORKER1_PRIV_IP=${WORKER1_PRIV_IP}"
    echo ""
    echo "WORKER2_INSTANCE_ID=${WORKER2_INSTANCE_ID}"
    echo "WORKER2_PRIV_IP=${WORKER2_PRIV_IP}"
    echo ""
    echo "# SSM paths -- used by --teardown for cleanup"
    echo "SSM_MASTER_IP=${SSM_MASTER_IP}"
    echo "SSM_JOIN_TOKEN=${SSM_JOIN_TOKEN}"
    echo "SSM_JOIN_HASH=${SSM_JOIN_HASH}"
  } > "${STATE_FILE}"
  ok "State saved: ${STATE_FILE}"

  # Block here while master-init.sh runs and writes to SSM
  wait_join_params || true

  # Print final summary
  echo ""
  echo -e "${GREEN}${BOLD}+============================================================+${RESET}"
  echo -e "${GREEN}${BOLD}|              PROVISIONING COMPLETE                        |${RESET}"
  echo -e "${GREEN}${BOLD}+============================================================+${RESET}"
  echo ""
  echo -e "${CYAN}  Instances:${RESET}"
  printf "  %-30s  %-21s  pub=%-16s  priv=%s\n" \
    "${CLUSTER_NAME}-master"   "${MASTER_INSTANCE_ID}"  "${MASTER_PUB_IP}"   "${MASTER_PRIV_IP}"
  printf "  %-30s  %-21s  priv=%s\n" \
    "${CLUSTER_NAME}-worker-1" "${WORKER1_INSTANCE_ID}" "${WORKER1_PRIV_IP}"
  printf "  %-30s  %-21s  priv=%s\n" \
    "${CLUSTER_NAME}-worker-2" "${WORKER2_INSTANCE_ID}" "${WORKER2_PRIV_IP}"
  echo ""
  echo -e "${CYAN}  Connect via SSM Session Manager (no SSH required):${RESET}"
  echo -e "  ${YELLOW}# Master${RESET}"
  echo "  aws ssm start-session --profile ${AWS_PROFILE} --region ${AWS_REGION} --target ${MASTER_INSTANCE_ID}"
  echo -e "  ${YELLOW}# Worker-1${RESET}"
  echo "  aws ssm start-session --profile ${AWS_PROFILE} --region ${AWS_REGION} --target ${WORKER1_INSTANCE_ID}"
  echo -e "  ${YELLOW}# Worker-2${RESET}"
  echo "  aws ssm start-session --profile ${AWS_PROFILE} --region ${AWS_REGION} --target ${WORKER2_INSTANCE_ID}"
  echo ""
  echo -e "${CYAN}  Follow bootstrap logs (from inside an SSM session):${RESET}"
  echo -e "  ${YELLOW}sudo tail -f /var/log/k8s-master-bootstrap.log${RESET}   # on master"
  echo -e "  ${YELLOW}sudo tail -f /var/log/k8s-worker-bootstrap.log${RESET}   # on each worker"
  echo ""
  echo -e "${CYAN}  Verify cluster (from master, once bootstrap finishes):${RESET}"
  echo -e "  ${YELLOW}kubectl get nodes -o wide${RESET}"
  echo -e "  ${YELLOW}kubectl get pods -n kube-system${RESET}"
  echo ""
  echo -e "${CYAN}  Copy kubeconfig to your local machine:${RESET}"
  echo "  # SSM into master, then:"
  echo -e "  ${YELLOW}sudo cat /home/ubuntu/.kube/config${RESET}"
  echo ""
  echo -e "  State file  :  ${YELLOW}${STATE_FILE}${RESET}"
  echo -e "  Teardown    :  ${CYAN}bash $(basename "$0") --teardown${RESET}"
  echo ""
}
# =============================================================================
#  TEARDOWN
#  Terminates all 3 EC2 instances and deletes the SSM parameters.
# =============================================================================
teardown() {
  [[ -f "${STATE_FILE}" ]] \
    || fail "State file not found: ${STATE_FILE}\nSet STATE_FILE=<path> or run provisioning first."

  echo ""
  echo -e "${RED}${BOLD}+============================================================+${RESET}"
  echo -e "${RED}${BOLD}|                    TEARDOWN MODE                          |${RESET}"
  echo -e "${RED}${BOLD}+============================================================+${RESET}"
  echo ""
  echo -e "  Reading state from: ${YELLOW}${STATE_FILE}${RESET}"
  echo ""

  # shellcheck source=/dev/null
  source "${STATE_FILE}"

  # Collect all instance IDs present in the state file
  local -a term_ids=()
  for var in MASTER_INSTANCE_ID WORKER1_INSTANCE_ID WORKER2_INSTANCE_ID; do
    [[ -n "${!var:-}" ]] && term_ids+=("${!var}")
  done
  [[ ${#term_ids[@]} -eq 0 ]] && fail "No instance IDs found in ${STATE_FILE}."

  echo -e "  EC2 instances to terminate:"
  for iid in "${term_ids[@]}"; do
    local iname
    iname=$(aws ec2 describe-instances \
      --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
      --instance-ids "${iid}" \
      --query "Reservations[0].Instances[0].Tags[?Key=='Name']|[0].Value" \
      --output text 2>/dev/null || echo "unknown")
    echo -e "    ${RED}${iid}${RESET}  (${iname})"
  done
  echo ""

  echo -e "  SSM parameters to delete:"
  for p in "${SSM_MASTER_IP}" "${SSM_JOIN_TOKEN}" "${SSM_JOIN_HASH}"; do
    echo -e "    ${YELLOW}${p}${RESET}"
  done
  echo ""

  read -r -p "  Type 'yes' to confirm full teardown: " confirm
  echo ""
  [[ "${confirm}" == "yes" ]] \
    || { echo -e "  ${YELLOW}Aborted.${RESET} Nothing was changed."; exit 0; }

  # Terminate EC2 instances
  step "Terminating ${#term_ids[@]} EC2 instance(s)..."
  aws ec2 terminate-instances \
    --profile      "${AWS_PROFILE}" \
    --region       "${AWS_REGION}" \
    --instance-ids "${term_ids[@]}" \
    --output       table \
    --query        "TerminatingInstances[*].{ID:InstanceId,State:CurrentState.Name}"

  step "Waiting for all instances to reach 'terminated' state..."
  aws ec2 wait instance-terminated \
    --profile      "${AWS_PROFILE}" \
    --region       "${AWS_REGION}" \
    --instance-ids "${term_ids[@]}"
  ok "All instances terminated"

  # Delete SSM parameters
  # Capture stderr so we can distinguish ParameterNotFound (safe to ignore)
  # from any real error (AccessDenied, network, etc.) which should be shown.
  step "Deleting SSM parameters..."
  for p in "${SSM_MASTER_IP}" "${SSM_JOIN_TOKEN}" "${SSM_JOIN_HASH}"; do
    local ssm_err=""
    if ssm_err=$(aws ssm delete-parameter \
        --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
        --name    "${p}" 2>&1); then
      ok "Deleted : ${p}"
    elif echo "${ssm_err}" | grep -q "ParameterNotFound"; then
      warn "Not found (already gone): ${p}"
    else
      echo -e "${RED}[ERROR]${RESET} Failed to delete ${p}:"
      echo    "        ${ssm_err}"
    fi
  done

  # Archive the state file so teardown cannot be run twice accidentally
  mv "${STATE_FILE}" "${STATE_FILE}.destroyed"
  ok "State archived: ${STATE_FILE}.destroyed"

  echo ""
  echo -e "${GREEN}${BOLD}+============================================================+${RESET}"
  echo -e "${GREEN}${BOLD}|               TEARDOWN COMPLETE                           |${RESET}"
  echo -e "${GREEN}${BOLD}+============================================================+${RESET}"
  echo ""
}

# =============================================================================
#  DISPATCHER
# =============================================================================
case "${1:-}" in
  --teardown) teardown ;;
  "")         main ;;
  *) fail "Unknown argument: $1\nUsage: bash $(basename "$0") [--teardown]" ;;
esac