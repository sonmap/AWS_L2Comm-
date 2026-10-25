#!/usr/bin/env bash
# gcloud/90-teardown.sh 의 aws CLI 등가 구현
# terraform destroy 대체 - 생성 역순 삭제 (IAM 역할/정책은 수동 정리 필요)
# 위험한 작업이므로 각 단계마다 확인을 받습니다.

source "$(dirname "$0")/00-env.sh"

# 자원 생성/운영 단계 -> 배포 주체로 실행 (Owner 아님)
require_profile "${ADMIN_PROFILE}"
resolve_vpc_id || true

confirm() { read -r -p "$1 [y/N] " a; [[ "${a}" == "y" || "${a}" == "Y" ]]; }

if confirm "EKS Cluster ${CLUSTER_NAME} 삭제? (10~15분 소요)"; then
  # Auto Mode 는 노드 그룹이 없으므로 클러스터만 지우면 EC2 도 회수됩니다.
  aws eks delete-cluster --region "${REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  echo "삭제 대기 중..."
  aws eks wait cluster-deleted --region "${REGION}" --name "${CLUSTER_NAME}" 2>/dev/null || true
fi

if confirm "CodeBuild 프로젝트 ${CB_PROJECT} 삭제?"; then
  aws codebuild delete-webhook --region "${REGION}" --project-name "${CB_PROJECT}" >/dev/null 2>&1 || true
  aws codebuild delete-project --region "${REGION}" --name "${CB_PROJECT}" >/dev/null 2>&1 || true
fi

if confirm "EFS ${EFS_NAME} 삭제? (마운트 타깃과 데이터 전부 삭제됨)"; then
  if resolve_efs_id; then
    for MT in $(aws efs describe-mount-targets --region "${REGION}" \
                  --file-system-id "${EFS_ID}" \
                  --query 'MountTargets[].MountTargetId' --output text); do
      echo "  마운트 타깃 삭제: ${MT}"
      aws efs delete-mount-target --region "${REGION}" --mount-target-id "${MT}" || true
    done
    echo "  마운트 타깃 정리 대기 (최대 90초)"
    for _ in $(seq 1 18); do
      REMAIN="$(aws efs describe-mount-targets --region "${REGION}" \
        --file-system-id "${EFS_ID}" --query 'length(MountTargets)' --output text 2>/dev/null)"
      [[ "${REMAIN}" == "0" ]] && break
      sleep 5
    done
    aws efs delete-file-system --region "${REGION}" --file-system-id "${EFS_ID}" || true
  else
    echo "  EFS 를 찾지 못했습니다: ${EFS_NAME}"
  fi
fi

if confirm "ECR ${ECR_ACCOUNT}/${ECR_PYTHON}/${IMAGE_NAME} / ${ECR_HELM} 삭제? (이미지 전부 삭제됨)"; then
  aws ecr delete-repository --region "${REGION}" \
    --repository-name "${ECR_PYTHON}/${IMAGE_NAME}" --force >/dev/null 2>&1 || true
  aws ecr delete-repository --region "${REGION}" \
    --repository-name "${ECR_HELM}" --force >/dev/null 2>&1 || true
fi

if confirm "Glue 데이터베이스 ${TARGET_DATABASE} 와 Athena 워크그룹 ${ATHENA_WORKGROUP} 삭제?"; then
  aws glue delete-database --region "${REGION}" --name "${TARGET_DATABASE}" >/dev/null 2>&1 || true
  aws athena delete-work-group --region "${REGION}" \
    --work-group "${ATHENA_WORKGROUP}" --recursive-delete-option >/dev/null 2>&1 || true
fi

if confirm "S3 버킷 ${DATA_BUCKET} 삭제? (적재 데이터와 쿼리 결과 전부 삭제됨)"; then
  aws s3 rm "s3://${DATA_BUCKET}" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --region "${REGION}" --bucket "${DATA_BUCKET}" || true
fi

if confirm "서브넷 ${EKS_SUBNET_A_NAME} / ${EKS_SUBNET_C_NAME} / infra 2개 삭제? (클러스터 삭제 완료 후에만 가능)"; then
  for SN in "${EKS_SUBNET_A_NAME}" "${EKS_SUBNET_C_NAME}" \
            "${INFRA_SUBNET_A_NAME}" "${INFRA_SUBNET_C_NAME}"; do
    SID="$(subnet_id_by_name "${SN}")"
    if [[ -n "${SID}" && "${SID}" != "None" ]]; then
      echo "  서브넷 삭제: ${SN} (${SID})"
      aws ec2 delete-subnet --region "${REGION}" --subnet-id "${SID}" || true
    fi
  done
  echo "  (VPC 보조 CIDR ${POD_CIDR} 분리는 Owner 프로파일에서 수행하십시오)"
fi

echo
echo "IAM 역할, 보안그룹, VPC 엔드포인트, VPC 보조 CIDR 은 자동 삭제하지 않습니다."
echo "필요 시 아래를 직접 실행하십시오 (역할은 정책 분리 후 삭제):"
cat <<EOF

  # 애플리케이션 / 클러스터 / 노드 / CodeBuild 역할
  for R in ${ROLE_APP_NAME} ${ROLE_APP_NAME}-efs-csi ${ROLE_CLUSTER_NAME} ${ROLE_NODE_NAME} ${ROLE_CODEBUILD_NAME}; do
    for P in \$(aws iam list-attached-role-policies --role-name "\$R" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws iam detach-role-policy --role-name "\$R" --policy-arn "\$P"
    done
    for P in \$(aws iam list-role-policies --role-name "\$R" --query 'PolicyNames' --output text); do
      aws iam delete-role-policy --role-name "\$R" --policy-name "\$P"
    done
    aws iam delete-role --role-name "\$R"
  done

  # 보안그룹 (Owner 프로파일)
  AWS_PROFILE=${OWNER_PROFILE} aws ec2 delete-security-group --region ${REGION} \\
    --group-id \$(aws ec2 describe-security-groups --region ${REGION} \\
      --filters Name=group-name,Values=${SG_EFS_NAME} Name=vpc-id,Values=${VPC_ID} \\
      --query 'SecurityGroups[0].GroupId' --output text)
  # ... ${SG_CLUSTER_NAME}, ${SG_MGMT_NAME}, ${SG_VPCE_NAME} 도 동일

  # VPC 보조 CIDR 분리 (Owner 프로파일)
  AWS_PROFILE=${OWNER_PROFILE} aws ec2 disassociate-vpc-cidr-block --region ${REGION} \\
    --association-id <describe-vpcs 의 CidrBlockAssociationSet 에서 확인>
EOF
