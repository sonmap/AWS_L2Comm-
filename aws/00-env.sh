#!/usr/bin/env bash
# 공통 환경변수 - 모든 스크립트가 이 파일을 source 합니다.
# GCP 원본(gcloud/00-env.sh)의 값과 1:1 대응합니다. 매핑은 docs/MIGRATION.md 참고.

set -Eeuo pipefail

# ---- Account / Region (00-bootstrap, 10-network, 30-platform 공통) ----
#
# GCP 의 프로젝트 3분할을 AWS 계정 3분할로 옮겼습니다.
#   Edge  (gcp-prod-edp-edge-509423)  -> WORKLOAD : EKS / CodeBuild
#   Host  (gcp-prod-edp-hub-vpchost)  -> NETWORK  : VPC(공유) / ECR
#   Data  (pjt-c-admin)               -> DATA     : S3 / Glue / Athena
#
# 단일 계정에서 PoC 하는 경우 세 값을 모두 같은 계정 ID 로 두면 됩니다.
# 스크립트는 계정이 같아도 동작하도록 작성되어 있습니다.
export WORKLOAD_ACCOUNT="${WORKLOAD_ACCOUNT:-111122223333}"
export NETWORK_ACCOUNT="${NETWORK_ACCOUNT:-444455556666}"
export DATA_ACCOUNT="${DATA_ACCOUNT:-777788889999}"
export REGION="${REGION:-ap-northeast-2}"

# ---- 계정(프로파일) 분리 ----
#
# OWNER_PROFILE : Organization / Account 관리자.
#                 **IAM 과 네트워크(VPC/서브넷/보안그룹)를 만들 때만** 사용합니다.
#                 즉 00-bootstrap.sh, 10-network.sh, 11-securitygroup.sh 전용.
#
# ADMIN_PROFILE : 실제 배포/운영 주체.
#                 00-bootstrap.sh 에서 정책을 받은 뒤 20 단계부터 모든 작업을 수행합니다.
#
export OWNER_PROFILE="${OWNER_PROFILE:-l2comm-owner}"
export ADMIN_PROFILE="${ADMIN_PROFILE:-l2comm-admin}"

# 배포 주체 IAM 주체. User 또는 Role 중 실제로 쓰는 쪽을 지정합니다.
export ADMIN_PRINCIPAL_TYPE="${ADMIN_PRINCIPAL_TYPE:-user}"   # user | role
export ADMIN_PRINCIPAL_NAME="${ADMIN_PRINCIPAL_NAME:-l2comm-deployer}"

# 관리 EC2(구 infra-son01)의 인스턴스 프로파일 역할.
# GCP 의 VM_SA(620081195575-compute@...) 대응.
export VM_ROLE_NAME="${VM_ROLE_NAME:-role-l2comm-mgmt-ec2}"

# ---- Network ----
# GCP Shared VPC -> AWS RAM 으로 공유한 NETWORK 계정의 VPC.
export VPC_NAME="${VPC_NAME:-vpc-prod-edp-hub}"
export VPC_ID="${VPC_ID:-}"                       # 비우면 10-network.sh 가 이름으로 조회
export AZ_A="${AZ_A:-${REGION}a}"
export AZ_C="${AZ_C:-${REGION}c}"

# Node/Pod 서브넷.
#
# AWS VPC CNI 에는 GKE 의 "Pod Secondary Range" 개념이 없습니다.
# Pod 은 노드가 속한 서브넷의 IP 를 그대로 받습니다. 따라서 GCP 의
# Pod 대역(100.64.128.0/19)을 VPC 보조 CIDR 로 붙이고, 그 안에 EKS
# 노드/Pod 서브넷을 둬서 Pod 밀도를 흡수하도록 했습니다.
export POD_CIDR="${POD_CIDR:-100.64.128.0/19}"            # VPC 보조 CIDR
export EKS_SUBNET_A_NAME="${EKS_SUBNET_A_NAME:-subnet-prod-edp-l2comm-eks-a}"
export EKS_SUBNET_C_NAME="${EKS_SUBNET_C_NAME:-subnet-prod-edp-l2comm-eks-c}"
export EKS_SUBNET_A_CIDR="${EKS_SUBNET_A_CIDR:-100.64.128.0/20}"
export EKS_SUBNET_C_CIDR="${EKS_SUBNET_C_CIDR:-100.64.144.0/20}"

# 관리/EFS 서브넷. GCP 의 Node Primary(10.252.1.0/24)를 둘로 나눴습니다.
# EFS 마운트 타깃과 관리 EC2 가 여기 들어갑니다.
export NODE_CIDR="${NODE_CIDR:-10.252.1.0/24}"
export INFRA_SUBNET_A_NAME="${INFRA_SUBNET_A_NAME:-subnet-prod-edp-l2comm-infra-a}"
export INFRA_SUBNET_C_NAME="${INFRA_SUBNET_C_NAME:-subnet-prod-edp-l2comm-infra-c}"
export INFRA_SUBNET_A_CIDR="${INFRA_SUBNET_A_CIDR:-10.252.1.0/25}"
export INFRA_SUBNET_C_CIDR="${INFRA_SUBNET_C_CIDR:-10.252.1.128/25}"

# GCP 의 CONTROL_PLANE_CIDR(10.254.5.0/28) 대응값은 없습니다.
# EKS 는 Control Plane ENI 를 위 EKS 서브넷에 직접 생성하므로 별도 대역을
# 예약하지 않습니다. 접근 제어는 보안그룹(11-securitygroup.sh)으로 합니다.

# ---- Security Group 이름 (11) ----
export SG_CLUSTER_NAME="${SG_CLUSTER_NAME:-sg-l2comm-eks-cluster}"
export SG_EFS_NAME="${SG_EFS_NAME:-sg-l2comm-efs}"
export SG_MGMT_NAME="${SG_MGMT_NAME:-sg-l2comm-mgmt}"
export SG_VPCE_NAME="${SG_VPCE_NAME:-sg-l2comm-vpce}"

# ---- Platform (30) ----
export CLUSTER_NAME="${CLUSTER_NAME:-eks-l2comm-batch-an2}"
export K8S_VERSION="${K8S_VERSION:-1.31}"

# ECR 은 NETWORK(구 Host) 계정에 둡니다.
# Push(WORKLOAD 의 CodeBuild) / Pull(WORKLOAD 의 EKS 노드) 모두 크로스 계정입니다.
export ECR_ACCOUNT="${ECR_ACCOUNT:-${NETWORK_ACCOUNT}}"
export ECR_PYTHON="${ECR_PYTHON:-ar-l2comm-python}"
export ECR_HELM="${ECR_HELM:-ar-l2comm-helm}"
export IMAGE_NAME="${IMAGE_NAME:-python-athena-batch}"
export IMAGE_TAG="${IMAGE_TAG:-v1}"
export NAMESPACE="${NAMESPACE:-l2comm-batch}"
export KSA_NAME="${KSA_NAME:-ksa-l2comm-batch}"

# ---- EFS (구 VM 자체 NFS) ----
export EFS_NAME="${EFS_NAME:-efs-l2comm-rsvp}"
export EFS_ID="${EFS_ID:-}"                       # 비우면 30-platform.sh 가 이름으로 조회

# ---- CodeBuild / CodeConnections (20 / 30) ----
# GCP Cloud Build Connection/Repository/Trigger 대응.
export CC_CONNECTION="${CC_CONNECTION:-github-l2comm}"
export CB_REPO="${CB_REPO:-AWS_L2Comm-}"
export CB_REMOTE_URI="${CB_REMOTE_URI:-https://github.com/sonmap/AWS_L2Comm-.git}"
export CB_PROJECT="${CB_PROJECT:-cb-l2comm-python-image}"
export CB_BRANCH="${CB_BRANCH:-main}"

# ---- 분석 저장소 (구 BigQuery) ----
# BigQuery dataset/table -> Glue database/table + S3 + Athena
export TARGET_DATABASE="${TARGET_DATABASE:-dlk_sample}"
export TARGET_TABLE="${TARGET_TABLE:-aws_region_inventory}"
export DATA_BUCKET="${DATA_BUCKET:-l2comm-dlk-sample-${DATA_ACCOUNT}-${REGION}}"
export ATHENA_WORKGROUP="${ATHENA_WORKGROUP:-wg-l2comm}"
export ATHENA_OUTPUT="${ATHENA_OUTPUT:-s3://${DATA_BUCKET}/athena-results/}"

# ---- Batch 실행 (run-eks.sh / client_eks) ----
# EventBridge Scheduler / Step Functions 를 사용하지 않습니다.
# 정기 실행이 필요하면 관리 EC2 의 crontab 에서 run-eks.sh 를 호출합니다.
export POD_MOUNT_PATH="${POD_MOUNT_PATH:-/home/jupyter}"

# ---- 파생값 ----
# 통합 IAM 역할.
# GCP 의 sa-l2comm-gke 대응. Build / Runtime 전 구간에서 사용합니다.
export ROLE_APP_NAME="${ROLE_APP_NAME:-role-l2comm-eks}"
export ROLE_APP_ARN="arn:aws:iam::${WORKLOAD_ACCOUNT}:role/${ROLE_APP_NAME}"

# EKS Auto Mode 가 요구하는 2개 역할
export ROLE_CLUSTER_NAME="${ROLE_CLUSTER_NAME:-role-l2comm-eks-cluster}"
export ROLE_NODE_NAME="${ROLE_NODE_NAME:-role-l2comm-eks-node}"
export ROLE_CLUSTER_ARN="arn:aws:iam::${WORKLOAD_ACCOUNT}:role/${ROLE_CLUSTER_NAME}"
export ROLE_NODE_ARN="arn:aws:iam::${WORKLOAD_ACCOUNT}:role/${ROLE_NODE_NAME}"

export ROLE_CODEBUILD_NAME="${ROLE_CODEBUILD_NAME:-role-l2comm-codebuild}"
export ROLE_CODEBUILD_ARN="arn:aws:iam::${WORKLOAD_ACCOUNT}:role/${ROLE_CODEBUILD_NAME}"

export ECR_REGISTRY="${ECR_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
export IMAGE_URI="${ECR_REGISTRY}/${ECR_PYTHON}/${IMAGE_NAME}:${IMAGE_TAG}"
export HELM_OCI_URI="oci://${ECR_REGISTRY}/${ECR_HELM}"

if [[ "${ADMIN_PRINCIPAL_TYPE}" == "role" ]]; then
  export ADMIN_PRINCIPAL_ARN="arn:aws:iam::${WORKLOAD_ACCOUNT}:role/${ADMIN_PRINCIPAL_NAME}"
else
  export ADMIN_PRINCIPAL_ARN="arn:aws:iam::${WORKLOAD_ACCOUNT}:user/${ADMIN_PRINCIPAL_NAME}"
fi
export VM_ROLE_ARN="arn:aws:iam::${WORKLOAD_ACCOUNT}:role/${VM_ROLE_NAME}"

# ---- 공통 헬퍼 ----
# terraform 은 state 로 "이미 존재함"을 판별하지만 aws CLI 는 그렇지 않습니다.
# 아래 헬퍼로 재실행(멱등성)을 보장합니다.

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

# 현재 프로파일로 보이는 IAM 주체
current_principal() {  # current_principal [profile]
  aws sts get-caller-identity --profile "${1:-$ADMIN_PROFILE}" \
    --query 'Arn' --output text 2>/dev/null
}

# 실행 프로파일 확인.
#   require_profile "${OWNER_PROFILE}"  -> IAM/네트워크 단계
#   require_profile "${ADMIN_PROFILE}"  -> 배포 주체 단계
# SKIP_PROFILE_CHECK=1 로 우회할 수 있습니다.
require_profile() {
  local expected="$1" arn

  if [[ "${SKIP_PROFILE_CHECK:-0}" == "1" ]]; then
    log "프로파일 확인 생략 (SKIP_PROFILE_CHECK=1). 사용 프로파일: ${expected}"
    export AWS_PROFILE="${expected}"
    return 0
  fi

  if ! arn="$(current_principal "${expected}")" || [[ -z "${arn}" || "${arn}" == "None" ]]; then
    cat >&2 <<MSG
ERROR: 프로파일 '${expected}' 로 AWS 호출을 할 수 없습니다.

  프로파일 분리 원칙
    ${OWNER_PROFILE}  : IAM / 네트워크 관리 -> 00-bootstrap.sh, 10-network.sh, 11-securitygroup.sh
    ${ADMIN_PROFILE}  : 배포/운영 주체      -> 20 단계 이후 전부

  설정:
    aws configure --profile ${expected}
    (SSO 사용 시) aws sso login --profile ${expected}

  확인:
    aws sts get-caller-identity --profile ${expected}
MSG
    exit 1
  fi

  export AWS_PROFILE="${expected}"
  log "실행 주체 확인: ${arn}  (profile=${expected})"
}

# 이미 존재하면 *AlreadyExists* 류 오류를 무시하고 넘어감
ok_if_exists() {
  local out rc
  set +e
  out="$("$@" 2>&1)"; rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qiE 'AlreadyExists|already exists|ResourceInUseException|InvalidGroup\.Duplicate|EntityAlreadyExists|RepositoryAlreadyExists|BucketAlreadyOwnedByYou|InvalidPermission\.Duplicate|FileSystemAlreadyExists|MountTargetConflict|ResourceAlreadyExistsException' <<<"${out}"; then
      log "SKIP (이미 존재): $*"
      return 0
    fi
    printf '%s\n' "${out}" >&2
    return $rc
  fi
  printf '%s\n' "${out}"
}

# 관리형 정책 연결 (additive, 멱등)
attach_policies() {  # attach_policies <role_name> <policy_arn...>
  local role="$1"; shift
  local arn
  for arn in "$@"; do
    log "IAM ${role} -> ${arn}"
    aws iam attach-role-policy --role-name "${role}" --policy-arn "${arn}" >/dev/null
  done
}

# 인라인 정책 적용 (멱등: 같은 이름이면 덮어씀)
put_inline_policy() {  # put_inline_policy <role_name> <policy_name> <json>
  log "IAM inline ${1} :: ${2}"
  aws iam put-role-policy --role-name "$1" --policy-name "$2" \
    --policy-document "$3" >/dev/null
}

# 태그로 서브넷 ID 조회
subnet_id_by_name() {  # subnet_id_by_name <name> [profile]
  aws ec2 describe-subnets --profile "${2:-$AWS_PROFILE}" --region "${REGION}" \
    --filters "Name=tag:Name,Values=$1" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null
}

# 이름으로 보안그룹 ID 조회
sg_id_by_name() {  # sg_id_by_name <name> [vpc_id]
  aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=${2:-$VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null
}

# 이름으로 VPC ID 조회 (VPC_ID 가 비어 있을 때만)
resolve_vpc_id() {
  if [[ -z "${VPC_ID}" ]]; then
    VPC_ID="$(aws ec2 describe-vpcs --region "${REGION}" \
      --filters "Name=tag:Name,Values=${VPC_NAME}" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
  fi
  if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
    echo "ERROR: VPC 를 찾지 못했습니다: ${VPC_NAME}" >&2
    echo "       00-env.sh 의 VPC_NAME 을 확인하거나 VPC_ID 를 직접 지정하십시오." >&2
    return 1
  fi
  export VPC_ID
}

# 이름으로 EFS 파일 시스템 ID 조회 (EFS_ID 가 비어 있을 때만)
resolve_efs_id() {
  if [[ -z "${EFS_ID}" ]]; then
    EFS_ID="$(aws efs describe-file-systems --region "${REGION}" \
      --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId | [0]" \
      --output text 2>/dev/null)"
  fi
  if [[ -z "${EFS_ID}" || "${EFS_ID}" == "None" ]]; then
    return 1
  fi
  export EFS_ID
}
