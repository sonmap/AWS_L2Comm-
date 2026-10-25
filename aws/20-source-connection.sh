#!/usr/bin/env bash
# gcloud/20-source-connection.sh 의 aws CLI 등가 구현
#
# GCP Cloud Build Connection -> AWS CodeConnections (구 CodeStar Connections).
#
# ** 중요한 차이 **
# gcloud 는 Connection 아래에 저장소를 "등록"하는 2nd-gen 모델이지만,
# CodeConnections 는 GitHub 계정/조직 단위로 1개만 만들면 되고 개별 저장소를
# 따로 등록하지 않습니다. 저장소 지정은 30-platform.sh 의 CodeBuild 프로젝트
# 소스 설정에서 합니다.
#
# 또 하나: CodeConnections 생성 직후 상태는 PENDING 입니다.
# 브라우저에서 GitHub 핸드셰이크를 한 번 승인해야 AVAILABLE 이 됩니다.
# 이 단계는 CLI 로 끝낼 수 없습니다.

source "$(dirname "$0")/00-env.sh"

# 자원 생성/운영 단계 -> 배포 주체로 실행 (Owner 아님)
require_profile "${ADMIN_PROFILE}"

log "CodeConnections 연결 확인"
aws codeconnections list-connections --region "${REGION}" \
  --provider-type-filter GitHub \
  --query 'Connections[].{Name:ConnectionName,Status:ConnectionStatus,Arn:ConnectionArn}' \
  --output table

CONN_ARN="$(aws codeconnections list-connections --region "${REGION}" \
  --provider-type-filter GitHub \
  --query "Connections[?ConnectionName=='${CC_CONNECTION}'].ConnectionArn | [0]" \
  --output text 2>/dev/null)"

if [[ -n "${CONN_ARN}" && "${CONN_ARN}" != "None" ]]; then
  log "SKIP (이미 존재): ${CC_CONNECTION}"
else
  log "연결 생성: ${CC_CONNECTION}"
  CONN_ARN="$(aws codeconnections create-connection --region "${REGION}" \
    --provider-type GitHub \
    --connection-name "${CC_CONNECTION}" \
    --query 'ConnectionArn' --output text)"
fi

CONN_STATUS="$(aws codeconnections get-connection --region "${REGION}" \
  --connection-arn "${CONN_ARN}" \
  --query 'Connection.ConnectionStatus' --output text)"

log "CONNECTION_ARN = ${CONN_ARN}"
log "CONNECTION_STATUS = ${CONN_STATUS}"

if [[ "${CONN_STATUS}" != "AVAILABLE" ]]; then
  cat <<EOF

=== 수동 작업 필요 ===
연결 상태가 ${CONN_STATUS} 입니다. 브라우저에서 한 번 승인해야 AVAILABLE 이 됩니다.
CLI 로는 완료할 수 없습니다.

  1) AWS 콘솔 > Developer Tools > Settings > Connections
     리전: ${REGION}
     https://${REGION}.console.aws.amazon.com/codesuite/settings/connections?region=${REGION}

  2) '${CC_CONNECTION}' 선택 > [Update pending connection]

  3) GitHub 앱 설치 화면에서 'sonmap' 계정/조직 선택
     Repository access 에 '${CB_REPO}' 가 포함되어야 합니다.
     ('All repositories' 로 설정되어 있으면 추가 작업 불필요)

  4) 다시 이 스크립트를 실행해 AVAILABLE 을 확인합니다.
     ./aws/20-source-connection.sh

이 단계를 건너뛰면 30-platform.sh 의 CodeBuild 프로젝트가 소스를 읽지 못하고
빌드가 CLIENT_ERROR 로 실패합니다.
EOF
  exit 1
fi

cat <<EOF

=== Outputs ===
connection_name : ${CC_CONNECTION}
connection_arn  : ${CONN_ARN}
status          : ${CONN_STATUS}
repository      : ${CB_REMOTE_URI}

이 ARN 을 30-platform.sh 가 CodeBuild 소스에 사용합니다.
고정하려면 00-env.sh 에 아래를 추가하십시오.

  export CC_CONNECTION_ARN="${CONN_ARN}"
EOF

log "20-source-connection 완료"
