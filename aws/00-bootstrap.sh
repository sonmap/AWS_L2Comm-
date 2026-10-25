#!/usr/bin/env bash
# gcloud/00-bootstrap.sh 의 aws CLI 등가 구현
#
# ** 이 스크립트만 Owner 프로파일(l2comm-owner)로 실행합니다. **
#
# GCP 에서는 "API 활성화 + IAM 부여"였습니다. AWS 에는 서비스 API 활성화
# 개념이 없으므로(모든 서비스가 기본 사용 가능) 이 단계는 IAM 역할/정책
# 부여와 서비스 연결 역할(Service-Linked Role) 생성만 수행합니다.
#
#   aws configure --profile l2comm-owner
#   ./aws/00-bootstrap.sh
#   # 이후 단계는 l2comm-admin 프로파일
#
# 주의: GCP 의 Infrastructure Manager(config.googleapis.com) 대응물은
#       사용하지 않습니다. CREATE_TFSTATE_BUCKET 는 산출물 보관용 선택사항입니다.

source "$(dirname "$0")/00-env.sh"

# 권한 부여 단계 -> Owner 로 실행
require_profile "${OWNER_PROFILE}"

CREATE_TFSTATE_BUCKET="${CREATE_TFSTATE_BUCKET:-false}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-l2comm-tfstate-${WORKLOAD_ACCOUNT}-${REGION}}"

###############################################################################
# 1) 서비스 연결 역할  (GCP 의 "API 활성화 + P4SA 생성" 대응)
#
#    GCP 는 services enable 시 Service Agent 가 자동 생성됩니다.
#    AWS 는 Service-Linked Role 을 명시적으로 만들어 두면 첫 호출이 느려지거나
#    권한 오류로 실패하는 일을 막을 수 있습니다. 이미 있으면 그냥 넘어갑니다.
###############################################################################
log "서비스 연결 역할 확인/생성"
for SVC in eks.amazonaws.com \
           elasticfilesystem.amazonaws.com \
           ecs.amazonaws.com \
           autoscaling.amazonaws.com; do
  ok_if_exists aws iam create-service-linked-role --aws-service-name "${SVC}" >/dev/null || true
done

###############################################################################
# 2) 산출물 버킷  (google_storage_bucket 대응)
#    -> aws CLI 전용 운영이면 불필요. 로그/산출물 보관용으로만 쓰려면 true.
###############################################################################
if [[ "${CREATE_TFSTATE_BUCKET}" == "true" ]]; then
  log "State 버킷 생성: ${TFSTATE_BUCKET}"
  ok_if_exists aws s3api create-bucket \
    --bucket "${TFSTATE_BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration "LocationConstraint=${REGION}"

  aws s3api put-bucket-versioning --bucket "${TFSTATE_BUCKET}" \
    --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "${TFSTATE_BUCKET}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
fi

###############################################################################
# 3) 관리 EC2 역할  (google_service_account / VM_SA 대응)
#
#    GCP 의 VM 기본 SA(620081195575-compute@...)에 해당합니다.
#    관리 EC2 에서 kubectl 과 aws CLI 를 돌리기 위한 인스턴스 프로파일입니다.
#    런타임용 통합 역할(role-l2comm-eks)은 30-platform.sh 에서 만듭니다.
###############################################################################
log "관리 EC2 역할: ${VM_ROLE_NAME}"
ok_if_exists aws iam create-role --role-name "${VM_ROLE_NAME}" \
  --description "L2Comm 관리 EC2 인스턴스 프로파일 역할" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' >/dev/null

ok_if_exists aws iam create-instance-profile \
  --instance-profile-name "${VM_ROLE_NAME}" >/dev/null
ok_if_exists aws iam add-role-to-instance-profile \
  --instance-profile-name "${VM_ROLE_NAME}" --role-name "${VM_ROLE_NAME}" >/dev/null

# SSM Session Manager 로 들어갈 수 있게 해 둡니다(공인 IP / 베스천 불필요).
attach_policies "${VM_ROLE_NAME}" \
  arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

###############################################################################
# 4) 배포 주체 권한  (google_project_iam_member 대응)
#
#    GCP 에서 ADMIN_USER 에게 직접 부여했던 Role 집합과 같은 범위를
#    AWS 관리형 정책 + 인라인 정책으로 옮겼습니다.
#
#    네트워크 관리(VPC/Subnet/SecurityGroup 생성)는 Owner 영역이므로
#    배포 주체에게 주지 않습니다. EKS 생성에 필요한 서브넷 접근은
#    10-network.sh 가 ec2:Describe* 범위로만 허용합니다.
###############################################################################
DEPLOYER_POLICY_NAME="L2CommDeployerPolicy"

read -r -d '' DEPLOYER_POLICY <<JSON || true
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EksAdmin",
      "Effect": "Allow",
      "Action": ["eks:*"],
      "Resource": "*"
    },
    {
      "Sid": "CodeBuildEditor",
      "Effect": "Allow",
      "Action": [
        "codebuild:*",
        "codeconnections:*",
        "codestar-connections:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EcrAdmin",
      "Effect": "Allow",
      "Action": ["ecr:*"],
      "Resource": "*"
    },
    {
      "Sid": "EfsAdmin",
      "Effect": "Allow",
      "Action": ["elasticfilesystem:*"],
      "Resource": "*"
    },
    {
      "Sid": "IamServiceAccountAdmin",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:ListRoles",
        "iam:TagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:PassRole",
        "iam:CreateServiceLinkedRole"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NetworkReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "elasticloadbalancing:Describe*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LogsViewer",
      "Effect": "Allow",
      "Action": [
        "logs:Describe*",
        "logs:Get*",
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "logs:GetQueryResults"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AnalyticsAdmin",
      "Effect": "Allow",
      "Action": [
        "athena:*",
        "glue:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DataBucket",
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": [
        "arn:aws:s3:::${DATA_BUCKET}",
        "arn:aws:s3:::${DATA_BUCKET}/*"
      ]
    }
  ]
}
JSON

log "배포 주체 정책: ${DEPLOYER_POLICY_NAME} -> ${ADMIN_PRINCIPAL_ARN}"
if [[ "${ADMIN_PRINCIPAL_TYPE}" == "role" ]]; then
  aws iam put-role-policy --role-name "${ADMIN_PRINCIPAL_NAME}" \
    --policy-name "${DEPLOYER_POLICY_NAME}" \
    --policy-document "${DEPLOYER_POLICY}" >/dev/null
else
  aws iam put-user-policy --user-name "${ADMIN_PRINCIPAL_NAME}" \
    --policy-name "${DEPLOYER_POLICY_NAME}" \
    --policy-document "${DEPLOYER_POLICY}" >/dev/null
fi

# 관리 EC2 에서 스크립트를 실행하는 경우 EC2 역할에도 동일 정책이 필요합니다.
# (GCP 의 GRANT_VM_DEPLOYER=true 대응)
if [[ "${GRANT_VM_DEPLOYER:-false}" == "true" ]]; then
  put_inline_policy "${VM_ROLE_NAME}" "${DEPLOYER_POLICY_NAME}" "${DEPLOYER_POLICY}"
fi

if [[ "${CREATE_TFSTATE_BUCKET}" == "true" ]]; then
  log "State 버킷 접근 권한은 위 DataBucket Sid 가 아닌 별도 정책이 필요합니다."
  log "  필요 시: aws iam put-user-policy ... (s3:*  arn:aws:s3:::${TFSTATE_BUCKET}/*)"
fi

log "00-bootstrap 완료"

cat <<EOF

=== 다음 단계 ===
네트워크 구성(10-network.sh)도 관리 영역이므로 Owner 프로파일로 이어서 실행합니다.

  ./aws/10-network.sh

그 이후(20 단계부터) 배포 주체로 전환합니다.

  export AWS_PROFILE=${ADMIN_PROFILE}
  ./aws/05-check-permissions.sh
  ./aws/20-source-connection.sh

부여된 정책 확인:
  aws iam list-attached-user-policies --user-name ${ADMIN_PRINCIPAL_NAME} --profile ${OWNER_PROFILE}
  aws iam get-user-policy --user-name ${ADMIN_PRINCIPAL_NAME} \\
    --policy-name ${DEPLOYER_POLICY_NAME} --profile ${OWNER_PROFILE}
EOF
