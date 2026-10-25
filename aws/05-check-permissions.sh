#!/usr/bin/env bash
# gcloud/05-check-permissions.sh 의 aws CLI 등가 구현
#
# 배포 주체(l2comm-admin)가 20/30 단계를 수행할 권한을 갖추었는지 사전 점검합니다.
#
# 실행 시점: 00-bootstrap.sh / 10-network.sh / 11-securitygroup.sh (Owner) 완료 후,
#            20-source-connection.sh 실행 전.
# 실행 주체: 배포 주체. simulate-principal-policy 는 지정한 주체의 유효 권한을
#            반환하므로 반드시 점검 대상 ARN 으로 실행해야 의미가 있습니다.
#
# 권한이 부족하면 어떤 Action 이 빠졌는지 알려주고 exit 1 합니다.
#
# 참고: iam:SimulatePrincipalPolicy 자체에 권한이 없으면 시뮬레이션 대신
#       실제 read-only 호출로 대체 점검합니다(DEGRADED 모드).

source "$(dirname "$0")/00-env.sh"

require_profile "${ADMIN_PROFILE}"

FAIL=0
SIMULATE_OK=1

if ! aws iam simulate-principal-policy \
       --policy-source-arn "${ADMIN_PRINCIPAL_ARN}" \
       --action-names "sts:GetCallerIdentity" >/dev/null 2>&1; then
  SIMULATE_OK=0
  printf '  \033[1;33mNOTE\033[0m iam:SimulatePrincipalPolicy 사용 불가 -> 실호출 점검으로 대체\n\n'
fi

###############################################################################
# 시뮬레이션 기반 점검
###############################################################################
check_actions() {  # check_actions <힌트> <action...>
  local hint="$1"; shift
  local denied

  if [[ ${SIMULATE_OK} -eq 0 ]]; then
    return 0
  fi

  denied="$(aws iam simulate-principal-policy \
    --policy-source-arn "${ADMIN_PRINCIPAL_ARN}" \
    --action-names "$@" \
    --query 'EvaluationResults[?EvalDecision!=`allowed`].EvalActionName' \
    --output text 2>/dev/null)"

  if [[ -z "${denied}" ]]; then
    printf '  \033[1;32mOK\033[0m   %s\n' "${hint}"
  else
    FAIL=1
    printf '  \033[1;31mFAIL\033[0m %s\n' "${hint}"
    printf '       거부: %s\n' "${denied}"
  fi
}

# 실호출 기반 점검 (시뮬레이션이 불가능할 때)
check_call() {  # check_call <힌트> <command...>
  local hint="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[1;32mOK\033[0m   %s\n' "${hint}"
  else
    FAIL=1
    printf '  \033[1;31mFAIL\033[0m %s\n' "${hint}"
    printf '       실패한 호출: %s\n' "$*"
  fi
}

log "배포 주체 권한 점검: ${ADMIN_PRINCIPAL_ARN}"
echo

echo "[Workload] ${WORKLOAD_ACCOUNT}"
if [[ ${SIMULATE_OK} -eq 1 ]]; then
  check_actions "codeconnections / codebuild (20 단계)" \
    codeconnections:ListConnections \
    codeconnections:GetConnection \
    codebuild:CreateProject \
    codebuild:ListProjects
  check_actions "codebuild 실행 (30/9 단계)" \
    codebuild:StartBuild \
    codebuild:BatchGetBuilds
  check_actions "eks 클러스터 생성 (30 단계)" \
    eks:CreateCluster \
    eks:DescribeCluster \
    eks:CreateAddon \
    eks:CreatePodIdentityAssociation
  check_actions "iam 역할 생성 / PassRole (30 단계)" \
    iam:CreateRole \
    iam:AttachRolePolicy \
    iam:PutRolePolicy \
    iam:PassRole
  check_actions "efs 생성 (30 단계)" \
    elasticfilesystem:CreateFileSystem \
    elasticfilesystem:CreateMountTarget \
    elasticfilesystem:DescribeFileSystems
  check_actions "ec2 조회 (서브넷/보안그룹 참조)" \
    ec2:DescribeSubnets \
    ec2:DescribeSecurityGroups \
    ec2:DescribeVpcs
else
  check_call "codeconnections 조회" aws codeconnections list-connections --region "${REGION}" --max-results 1
  check_call "codebuild 조회"       aws codebuild list-projects --region "${REGION}"
  check_call "eks 조회"             aws eks list-clusters --region "${REGION}"
  check_call "efs 조회"             aws efs describe-file-systems --region "${REGION}" --max-items 1
  check_call "ec2 서브넷 조회"      aws ec2 describe-subnets --region "${REGION}" --max-items 1
fi

echo
echo "[ECR] ${ECR_ACCOUNT}"
if [[ ${SIMULATE_OK} -eq 1 ]]; then
  check_actions "ecr 저장소 생성/정책 (30 단계)" \
    ecr:CreateRepository \
    ecr:SetRepositoryPolicy \
    ecr:DescribeRepositories \
    ecr:GetAuthorizationToken
else
  check_call "ecr 조회" aws ecr describe-repositories --region "${REGION}" --max-items 1
fi

echo
echo "[Data] ${DATA_ACCOUNT} / ${TARGET_DATABASE}"
if [[ ${SIMULATE_OK} -eq 1 ]]; then
  check_actions "glue 데이터베이스 (30/12 단계)" \
    glue:CreateDatabase \
    glue:GetDatabase \
    glue:CreateTable \
    glue:GetTable
  check_actions "athena 쿼리 실행" \
    athena:StartQueryExecution \
    athena:GetQueryExecution \
    athena:GetQueryResults \
    athena:CreateWorkGroup
else
  check_call "glue 조회"   aws glue get-databases --region "${REGION}" --max-results 1
  check_call "athena 조회" aws athena list-work-groups --region "${REGION}" --max-results 1
fi

###############################################################################
# 서브넷 / 보안그룹 존재 점검 (10-network.sh / 11-securitygroup.sh 가 생성)
###############################################################################
echo
echo "[Network] ${VPC_NAME}"
if resolve_vpc_id 2>/dev/null; then
  printf '  \033[1;32mOK\033[0m   VPC %s\n' "${VPC_ID}"

  for SN in "${EKS_SUBNET_A_NAME}" "${EKS_SUBNET_C_NAME}" \
            "${INFRA_SUBNET_A_NAME}" "${INFRA_SUBNET_C_NAME}"; do
    SID="$(subnet_id_by_name "${SN}")"
    if [[ -n "${SID}" && "${SID}" != "None" ]]; then
      printf '  \033[1;32mOK\033[0m   서브넷 %s = %s\n' "${SN}" "${SID}"
    else
      FAIL=1
      printf '  \033[1;31mFAIL\033[0m 서브넷 없음: %s\n' "${SN}"
      printf '       Owner 프로파일로 10-network.sh 를 재실행하십시오.\n'
    fi
  done

  for SG in "${SG_CLUSTER_NAME}" "${SG_EFS_NAME}" "${SG_MGMT_NAME}"; do
    GID="$(sg_id_by_name "${SG}")"
    if [[ -n "${GID}" && "${GID}" != "None" ]]; then
      printf '  \033[1;32mOK\033[0m   보안그룹 %s = %s\n' "${SG}" "${GID}"
    else
      FAIL=1
      printf '  \033[1;31mFAIL\033[0m 보안그룹 없음: %s\n' "${SG}"
      printf '       Owner 프로파일로 11-securitygroup.sh 를 재실행하십시오.\n'
    fi
  done
else
  printf '  \033[1;33mSKIP\033[0m VPC 를 조회할 수 없습니다 (이름 불일치이거나 조회 권한 없음)\n'
fi

###############################################################################
# 결과
###############################################################################
echo
if [[ ${FAIL} -eq 0 ]]; then
  log "점검 통과. 20-source-connection.sh 를 진행하십시오."
else
  cat <<EOF

=== 조치 방법 ===
Owner 프로파일로 전환해 00-bootstrap.sh 를 재실행하면 누락된 권한이 부여됩니다.

  export AWS_PROFILE=${OWNER_PROFILE}
  ./aws/00-bootstrap.sh
  ./aws/10-network.sh            # 서브넷이 FAIL 인 경우
  ./aws/11-securitygroup.sh      # 보안그룹이 FAIL 인 경우
  export AWS_PROFILE=${ADMIN_PROFILE}
  ./aws/05-check-permissions.sh

개별 Action 만 허용하려면 (Owner 프로파일로) 배포 주체의 인라인 정책
L2CommDeployerPolicy 를 편집하십시오:

  aws iam get-user-policy --user-name ${ADMIN_PRINCIPAL_NAME} \\
    --policy-name L2CommDeployerPolicy
EOF
  exit 1
fi
