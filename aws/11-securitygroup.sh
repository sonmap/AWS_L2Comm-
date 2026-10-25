#!/usr/bin/env bash
# gcloud/11-firewall.sh 의 aws CLI 등가 구현
#
# ** 이 스크립트는 Owner 프로파일(l2comm-owner)로 실행합니다. **
# VPC 보안그룹 변경이므로 네트워크 관리 영역입니다.
#
# 생성하는 보안그룹 3종:
#   1) sg-l2comm-eks-cluster : EKS 클러스터/노드 전용 SG
#   2) sg-l2comm-efs         : EFS 마운트 타깃. 클러스터 SG 와 관리 SG 에서 2049 허용
#   3) sg-l2comm-mgmt        : 관리 EC2
#
# GCP 와의 차이 — 중요
#   GCP 에서는 "Control Plane -> Node (tcp:10250 등)" 규칙을 Host 프로젝트에
#   직접 만들어야 konnectivity 가 붙었습니다. EKS 는 클러스터 보안그룹이
#   Control Plane ENI 와 노드에 모두 붙고 자기 자신(self) 통신을 허용하므로
#   이 규칙을 따로 만들 필요가 없습니다. 아래 4) 에서 self 규칙만 확인합니다.
#
# 선행: 10-network.sh (서브넷) 완료
#
# 환경변수(선택):
#   MGMT_INSTANCE_ID   관리 EC2. 생략하면 이 스크립트를 실행 중인 EC2 를
#                      IMDSv2 로 자동 인식해 sg-l2comm-mgmt 를 붙입니다.
#   SKIP_MGMT_SG=true  관리 EC2 에 SG 를 붙이지 않음(이미 붙어 있는 경우)

source "$(dirname "$0")/00-env.sh"

# 네트워크 관리 영역 -> Owner 로 실행
require_profile "${OWNER_PROFILE}"
resolve_vpc_id

###############################################################################
# 0) 현재 보안그룹 확인
###############################################################################
log "현재 ${VPC_NAME} (${VPC_ID}) 보안그룹"
aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[].{Name:GroupName,Id:GroupId,Desc:Description}' \
  --output table
echo

ensure_sg() {  # ensure_sg <name> <description>
  local name="$1" desc="$2" sid
  sid="$(sg_id_by_name "${name}")"
  if [[ -n "${sid}" && "${sid}" != "None" ]]; then
    printf '%s' "${sid}"
    return 0
  fi
  sid="$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${name}" --vpc-id "${VPC_ID}" --description "${desc}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}}]" \
    --query 'GroupId' --output text)"
  printf '%s' "${sid}"
}

SG_CLUSTER="$(ensure_sg "${SG_CLUSTER_NAME}" "L2Comm EKS cluster and nodes")"
SG_EFS="$(ensure_sg "${SG_EFS_NAME}" "L2Comm EFS mount targets")"
SG_MGMT="$(ensure_sg "${SG_MGMT_NAME}" "L2Comm management EC2")"

log "SG_CLUSTER=${SG_CLUSTER}"
log "SG_EFS=${SG_EFS}"
log "SG_MGMT=${SG_MGMT}"

###############################################################################
# 1) EKS Node/Pod -> EFS (tcp:2049)
#    GCP 의 fw-allow-l2comm-nfs 대응.
###############################################################################
log "EFS 규칙: ${SG_EFS_NAME} <- ${SG_CLUSTER_NAME} tcp/2049"
ok_if_exists aws ec2 authorize-security-group-ingress --region "${REGION}" \
  --group-id "${SG_EFS}" \
  --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=${SG_CLUSTER},Description=EKS nodes/pods to EFS}]" \
  >/dev/null

log "EFS 규칙: ${SG_EFS_NAME} <- ${SG_MGMT_NAME} tcp/2049 (관리 EC2 가 mnt/ 동기화)"
ok_if_exists aws ec2 authorize-security-group-ingress --region "${REGION}" \
  --group-id "${SG_EFS}" \
  --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=${SG_MGMT},Description=Management EC2 to EFS}]" \
  >/dev/null

###############################################################################
# 2) 관리 EC2 에 SG 부여
#    GCP 의 "NFS 서버 VM 에 l2comm-nfs 태그 부여" 대응.
###############################################################################
if [[ "${SKIP_MGMT_SG:-false}" != "true" ]]; then
  # 지정이 없으면 이 스크립트를 실행 중인 EC2 를 IMDSv2 로 자동 인식
  if [[ -z "${MGMT_INSTANCE_ID:-}" ]]; then
    IMDS_TOKEN="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 120" --max-time 2 2>/dev/null || true)"
    if [[ -n "${IMDS_TOKEN}" ]]; then
      MGMT_INSTANCE_ID="$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
        --max-time 2 "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)"
    fi
  fi

  if [[ -n "${MGMT_INSTANCE_ID:-}" ]]; then
    log "관리 EC2: ${MGMT_INSTANCE_ID} -> ${SG_MGMT_NAME}"

    # 인스턴스가 보이지 않으면(계정 오인/권한 부족) 전체 실패시키지 않고
    # 안내만 남긴 뒤 다음 단계로 진행합니다.
    if ! CUR_SGS="$(aws ec2 describe-instances --region "${REGION}" \
           --instance-ids "${MGMT_INSTANCE_ID}" \
           --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' \
           --output text 2>/dev/null)"; then
      log "WARN: 인스턴스를 찾지 못했습니다: ${MGMT_INSTANCE_ID}"
      log "      계정/리전을 확인한 뒤 아래처럼 지정해 재실행하십시오."
      log "        aws ec2 describe-instances --region ${REGION} \\"
      log "          --filters 'Name=tag:Name,Values=infra-son01' \\"
      log "          --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output table"
      log "        MGMT_INSTANCE_ID=<ID> ./aws/11-securitygroup.sh"
    elif grep -qw "${SG_MGMT}" <<<"${CUR_SGS}"; then
      log "SKIP (이미 보유): ${SG_MGMT}"
    else
      # modify-instance-attribute 는 목록을 치환하므로 기존 SG 를 합쳐 전달합니다.
      # shellcheck disable=SC2086
      aws ec2 modify-instance-attribute --region "${REGION}" \
        --instance-id "${MGMT_INSTANCE_ID}" \
        --groups ${CUR_SGS} "${SG_MGMT}"
      log "부여 완료"
    fi
  else
    log "SKIP: 관리 EC2 를 식별하지 못했습니다(IMDS 없음)."
    log "      MGMT_INSTANCE_ID 를 지정해 재실행하거나 콘솔에서 직접 부여하십시오:"
    log "        MGMT_INSTANCE_ID=<ID> ./aws/11-securitygroup.sh"
  fi
fi

###############################################################################
# 3) 관리 EC2 -> EKS API (tcp:443)
#    Private 엔드포인트 클러스터이므로 kubectl 은 VPC 내부에서만 됩니다.
###############################################################################
log "EKS API 규칙: ${SG_CLUSTER_NAME} <- ${SG_MGMT_NAME} tcp/443"
ok_if_exists aws ec2 authorize-security-group-ingress --region "${REGION}" \
  --group-id "${SG_CLUSTER}" \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs=[{GroupId=${SG_MGMT},Description=kubectl from management EC2}]" \
  >/dev/null

###############################################################################
# 4) Control Plane <-> Node 통신 (self 규칙)
#
#    GCP 의 fw-l2comm-master-to-node 대응.
#    EKS 는 클러스터 SG 를 Control Plane ENI 와 노드에 함께 붙이므로
#    self 규칙 하나로 10250 / 443 / webhook 포트가 모두 열립니다.
#    GCP 처럼 노드 네트워크 태그를 조회할 필요가 없습니다.
###############################################################################
log "Control Plane <-> Node self 규칙"
ok_if_exists aws ec2 authorize-security-group-ingress --region "${REGION}" \
  --group-id "${SG_CLUSTER}" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${SG_CLUSTER},Description=EKS control plane and nodes}]" \
  >/dev/null

###############################################################################
# 5) 결과
###############################################################################
echo
log "결과"
for SID in "${SG_CLUSTER}" "${SG_EFS}" "${SG_MGMT}"; do
  echo "--- ${SID} ---"
  aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SID}" \
    --query 'SecurityGroups[0].{Name:GroupName,Ingress:IpPermissions}' --output yaml
done

cat <<EOF

=== Outputs ===
SG_CLUSTER : ${SG_CLUSTER}
SG_EFS     : ${SG_EFS}
SG_MGMT    : ${SG_MGMT}

=== 다음 단계 ===
배포 주체로 전환한 뒤 노드 상태를 확인하십시오.

  export AWS_PROFILE=${ADMIN_PROFILE}
  aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION} \\
    --kubeconfig \$HOME/.kube/config_eks-automode
  KUBECONFIG=\$HOME/.kube/config_eks-automode kubectl get nodes

기대: 노드가 Ready. 이후 kubectl logs / exec 가 정상 동작합니다.
EOF

log "11-securitygroup 완료"
