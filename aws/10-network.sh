#!/usr/bin/env bash
# gcloud/10-network.sh 의 aws CLI 등가 구현
#
# ** 이 스크립트는 Owner 프로파일(l2comm-owner)로 실행합니다. **
#
# VPC 보조 CIDR 추가, 서브넷 생성, RAM 공유, VPC 엔드포인트 생성은
# 모두 네트워크 관리 영역이므로 Owner 가 수행합니다.
# AWS Organizations 수준 권한이 필요한 작업(RAM 공유 활성화)도
# 여기에 포함되므로 배포 주체 프로파일로는 수행하지 않습니다.
#
#   export AWS_PROFILE=l2comm-owner
#   ./aws/10-network.sh
#   export AWS_PROFILE=l2comm-admin    # 이후 단계

source "$(dirname "$0")/00-env.sh"

# 네트워크 관리 영역 -> Owner 로 실행
require_profile "${OWNER_PROFILE}"
resolve_vpc_id

###############################################################################
# 0) 사전 확인 - CIDR 중복 검사
###############################################################################
log "VPC ${VPC_NAME} (${VPC_ID}) 의 기존 CIDR / 서브넷 확인"
aws ec2 describe-vpcs --region "${REGION}" --vpc-ids "${VPC_ID}" \
  --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock' --output table

aws ec2 describe-subnets --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Cidr:CidrBlock,AZ:AvailabilityZone}' \
  --output table

echo
echo "아래 대역이 위 목록 및 On-Prem/VPN 과 겹치지 않는지 확인하십시오:"
echo "  Pod/Node (보조 CIDR)  ${POD_CIDR}"
echo "    - ${EKS_SUBNET_A_NAME}  ${EKS_SUBNET_A_CIDR}  (${AZ_A})"
echo "    - ${EKS_SUBNET_C_NAME}  ${EKS_SUBNET_C_CIDR}  (${AZ_C})"
echo "  관리/EFS (기본 CIDR)  ${NODE_CIDR}"
echo "    - ${INFRA_SUBNET_A_NAME}  ${INFRA_SUBNET_A_CIDR}  (${AZ_A})"
echo "    - ${INFRA_SUBNET_C_NAME}  ${INFRA_SUBNET_C_CIDR}  (${AZ_C})"
echo
echo "AWS VPC CNI 에는 GKE 의 Pod Secondary Range 가 없습니다."
echo "Pod 은 노드 서브넷 IP 를 직접 받으므로 ${POD_CIDR} 를 보조 CIDR 로 붙여"
echo "그 안에 EKS 노드/Pod 서브넷을 둡니다. Service 대역은 EKS 관리입니다."
read -r -p "계속하려면 Enter, 중단하려면 Ctrl+C: " _

###############################################################################
# 1) VPC 보조 CIDR 추가  (GKE Pod Secondary Range 대응)
###############################################################################
log "VPC 보조 CIDR 추가: ${POD_CIDR}"
if aws ec2 describe-vpcs --region "${REGION}" --vpc-ids "${VPC_ID}" \
     --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock' --output text \
     | tr '\t' '\n' | grep -qx "${POD_CIDR}"; then
  log "SKIP (이미 연결됨): ${POD_CIDR}"
else
  aws ec2 associate-vpc-cidr-block --region "${REGION}" \
    --vpc-id "${VPC_ID}" --cidr-block "${POD_CIDR}" >/dev/null
fi

###############################################################################
# 2) 서브넷 생성  (google_compute_subnetwork 대응)
#    - EKS 서브넷 2개(AZ 2곳): 노드 + Pod + Control Plane ENI
#    - 관리/EFS 서브넷 2개: EFS 마운트 타깃, 관리 EC2
#    - EKS 는 최소 2개 AZ 를 요구합니다.
###############################################################################
create_subnet() {  # create_subnet <name> <cidr> <az> <role>
  local name="$1" cidr="$2" az="$3" role="$4" sid

  sid="$(subnet_id_by_name "${name}")"
  if [[ -n "${sid}" && "${sid}" != "None" ]]; then
    log "SKIP (이미 존재): ${name} = ${sid}"
    printf '%s' "${sid}"
    return 0
  fi

  sid="$(aws ec2 create-subnet --region "${REGION}" \
    --vpc-id "${VPC_ID}" --cidr-block "${cidr}" --availability-zone "${az}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=l2comm-role,Value=${role}}]" \
    --query 'Subnet.SubnetId' --output text)"

  # 사설 서브넷이므로 공인 IP 자동 할당은 꺼 둡니다.
  aws ec2 modify-subnet-attribute --region "${REGION}" \
    --subnet-id "${sid}" --no-map-public-ip-on-launch

  log "생성: ${name} = ${sid} (${cidr}, ${az})"
  printf '%s' "${sid}"
}

EKS_SUBNET_A="$(create_subnet "${EKS_SUBNET_A_NAME}" "${EKS_SUBNET_A_CIDR}" "${AZ_A}" eks)"
EKS_SUBNET_C="$(create_subnet "${EKS_SUBNET_C_NAME}" "${EKS_SUBNET_C_CIDR}" "${AZ_C}" eks)"
INFRA_SUBNET_A="$(create_subnet "${INFRA_SUBNET_A_NAME}" "${INFRA_SUBNET_A_CIDR}" "${AZ_A}" infra)"
INFRA_SUBNET_C="$(create_subnet "${INFRA_SUBNET_C_NAME}" "${INFRA_SUBNET_C_CIDR}" "${AZ_C}" infra)"

# EKS 가 사설 서브넷을 인식하도록 하는 태그.
# Auto Mode 는 kubernetes.io/role/internal-elb 가 있어야 내부 LB 를 배치합니다.
for SID in "${EKS_SUBNET_A}" "${EKS_SUBNET_C}"; do
  aws ec2 create-tags --region "${REGION}" --resources "${SID}" \
    --tags "Key=kubernetes.io/role/internal-elb,Value=1" \
           "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
done

###############################################################################
# 3) 서브넷 공유  (google_compute_shared_vpc_service_project 대응)
#
#    GCP Shared VPC -> AWS RAM 서브넷 공유.
#    NETWORK 계정과 WORKLOAD 계정이 같으면 공유가 필요 없으므로 건너뜁니다.
###############################################################################
if [[ "${NETWORK_ACCOUNT}" == "${WORKLOAD_ACCOUNT}" ]]; then
  log "SKIP: NETWORK 계정과 WORKLOAD 계정이 동일하므로 RAM 공유 불필요"
else
  log "RAM 서브넷 공유: ${NETWORK_ACCOUNT} -> ${WORKLOAD_ACCOUNT}"
  RAM_NAME="ram-l2comm-eks-subnets"
  RAM_ARN="$(aws ram get-resource-shares --region "${REGION}" \
    --resource-owner SELF --name "${RAM_NAME}" \
    --query 'resourceShares[0].resourceShareArn' --output text 2>/dev/null || true)"

  if [[ -n "${RAM_ARN}" && "${RAM_ARN}" != "None" ]]; then
    log "SKIP (이미 존재): ${RAM_NAME}"
  else
    aws ram create-resource-share --region "${REGION}" \
      --name "${RAM_NAME}" \
      --principals "${WORKLOAD_ACCOUNT}" \
      --resource-arns \
        "arn:aws:ec2:${REGION}:${NETWORK_ACCOUNT}:subnet/${EKS_SUBNET_A}" \
        "arn:aws:ec2:${REGION}:${NETWORK_ACCOUNT}:subnet/${EKS_SUBNET_C}" \
        "arn:aws:ec2:${REGION}:${NETWORK_ACCOUNT}:subnet/${INFRA_SUBNET_A}" \
        "arn:aws:ec2:${REGION}:${NETWORK_ACCOUNT}:subnet/${INFRA_SUBNET_C}" \
      >/dev/null
    log "RAM 공유 생성 완료. 수신 계정에서 초대를 수락해야 할 수 있습니다."
    log "  aws ram get-resource-share-invitations --profile ${ADMIN_PROFILE}"
  fi
fi

###############################################################################
# 4) VPC 엔드포인트  (private-ip-google-access 대응)
#
#    GCP 는 Private Google Access 한 줄로 끝났지만 AWS 는 서비스별
#    엔드포인트가 필요합니다. NAT Gateway 없이 사설 서브넷에서
#    ECR Pull / S3 / Athena / Glue / EKS Pod Identity 를 쓰려면 아래가 필수입니다.
###############################################################################
log "VPC 엔드포인트용 보안그룹: ${SG_VPCE_NAME}"
SG_VPCE="$(sg_id_by_name "${SG_VPCE_NAME}")"
if [[ -z "${SG_VPCE}" || "${SG_VPCE}" == "None" ]]; then
  SG_VPCE="$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${SG_VPCE_NAME}" --vpc-id "${VPC_ID}" \
    --description "L2Comm VPC interface endpoints" \
    --query 'GroupId' --output text)"
fi
# VPC 내부에서의 HTTPS 만 허용
for CIDR in "${POD_CIDR}" "${NODE_CIDR}"; do
  ok_if_exists aws ec2 authorize-security-group-ingress --region "${REGION}" \
    --group-id "${SG_VPCE}" --protocol tcp --port 443 --cidr "${CIDR}" >/dev/null
done

ROUTE_TABLES="$(aws ec2 describe-route-tables --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].RouteTableId' --output text)"

log "게이트웨이 엔드포인트: S3"
if aws ec2 describe-vpc-endpoints --region "${REGION}" \
     --filters "Name=vpc-id,Values=${VPC_ID}" \
               "Name=service-name,Values=com.amazonaws.${REGION}.s3" \
     --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null \
     | grep -q '^vpce-'; then
  log "SKIP (이미 존재): S3 gateway endpoint"
else
  # shellcheck disable=SC2086
  aws ec2 create-vpc-endpoint --region "${REGION}" \
    --vpc-id "${VPC_ID}" \
    --service-name "com.amazonaws.${REGION}.s3" \
    --vpc-endpoint-type Gateway \
    --route-table-ids ${ROUTE_TABLES} >/dev/null
fi

for SVC in ecr.api ecr.dkr sts logs eks eks-auth elasticfilesystem athena glue ssm ssmmessages ec2messages; do
  FULL="com.amazonaws.${REGION}.${SVC}"
  if aws ec2 describe-vpc-endpoints --region "${REGION}" \
       --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${FULL}" \
       --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null \
       | grep -q '^vpce-'; then
    log "SKIP (이미 존재): ${FULL}"
    continue
  fi
  log "인터페이스 엔드포인트: ${FULL}"
  ok_if_exists aws ec2 create-vpc-endpoint --region "${REGION}" \
    --vpc-id "${VPC_ID}" \
    --service-name "${FULL}" \
    --vpc-endpoint-type Interface \
    --subnet-ids "${EKS_SUBNET_A}" "${EKS_SUBNET_C}" \
    --security-group-ids "${SG_VPCE}" \
    --private-dns-enabled >/dev/null
done

###############################################################################
# 5) 확인 (terraform output 대체)
###############################################################################
log "결과 확인"
aws ec2 describe-subnets --region "${REGION}" \
  --subnet-ids "${EKS_SUBNET_A}" "${EKS_SUBNET_C}" "${INFRA_SUBNET_A}" "${INFRA_SUBNET_C}" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone}' \
  --output table

cat <<EOF

=== Outputs ===
VPC_ID            : ${VPC_ID}
EKS_SUBNET_A      : ${EKS_SUBNET_A}   (${EKS_SUBNET_A_CIDR})
EKS_SUBNET_C      : ${EKS_SUBNET_C}   (${EKS_SUBNET_C_CIDR})
INFRA_SUBNET_A    : ${INFRA_SUBNET_A} (${INFRA_SUBNET_A_CIDR})
INFRA_SUBNET_C    : ${INFRA_SUBNET_C} (${INFRA_SUBNET_C_CIDR})
SG_VPCE           : ${SG_VPCE}

위 값을 00-env.sh 에 고정하려면 VPC_ID 만 채워 두면 됩니다.
나머지는 Name 태그로 매번 조회합니다.

=== 다음 단계 ===
보안그룹도 네트워크 관리 영역이므로 Owner 로 이어서 실행합니다.

  ./aws/11-securitygroup.sh

그 뒤 배포 주체로 전환합니다.

  export AWS_PROFILE=${ADMIN_PROFILE}
  ./aws/05-check-permissions.sh
EOF

log "10-network 완료"
