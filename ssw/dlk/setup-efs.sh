#!/usr/bin/env bash
set -euo pipefail

# gcloud 원본 ssw/dlk/setup-nfs-server.sh 의 AWS 등가 구현.
#
# GCP 에서는 관리 VM 이 직접 nfs-kernel-server 를 띄워 <repo>/mnt 를 export 했습니다.
# AWS 에서는 관리형 EFS 를 쓰므로 이 스크립트는 역할이 바뀝니다:
#   1) EFS 를 /srv/l2comm-efs 에 마운트 (amazon-efs-utils, TLS)
#   2) /etc/fstab 에 영구 항목 등록
#   3) 현재 체크아웃의 mnt/ 를 EFS 로 동기화 (rsync)
#
# 즉 "export" 가 아니라 "sync" 입니다. Pod 은 EFS CSI 로 같은 데이터를 읽습니다.
#
# 주의: .oefj 자격증명 파일은 Git 에 없으므로 rsync 에서 제외되지 않습니다.
#       EC2 안에서 mnt/batch_eks/l2/rsvp/.oefj 에 직접 두면 함께 동기화됩니다.

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GIT_MNT="$REPO_ROOT/mnt"
EFS_ROOT="${EFS_ROOT:-/srv/l2comm-efs}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
EFS_NAME="${EFS_NAME:-efs-l2comm-rsvp}"

if [[ ! -d "$GIT_MNT" ]]; then
  echo "ERROR: Git mnt directory not found: $GIT_MNT"
  exit 1
fi

###############################################################################
# 0) EFS ID 조회
###############################################################################
if [[ -z "${EFS_ID:-}" ]]; then
  EFS_ID="$(aws efs describe-file-systems --region "$AWS_REGION" \
    --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId | [0]" \
    --output text 2>/dev/null || true)"
fi
if [[ -z "${EFS_ID}" || "${EFS_ID}" == "None" ]]; then
  echo "ERROR: EFS file system not found: ${EFS_NAME}"
  echo "       aws/30-platform.sh 를 먼저 실행하거나 EFS_ID 를 지정하십시오."
  exit 1
fi
echo "[INFO] EFS_ID = ${EFS_ID}"

###############################################################################
# 1) amazon-efs-utils 설치
###############################################################################
if ! command -v mount.efs >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common git rsync binutils
    # Ubuntu 는 패키지가 없으므로 소스에서 deb 를 만듭니다.
    TMPD="$(mktemp -d)"
    git clone --depth 1 https://github.com/aws/efs-utils "$TMPD/efs-utils"
    ( cd "$TMPD/efs-utils" && ./build-deb.sh && apt-get -y install ./build/amazon-efs-utils*deb )
    rm -rf "$TMPD"
  else
    yum install -y amazon-efs-utils rsync
  fi
fi

###############################################################################
# 2) 마운트 (TLS 전송 암호화)
###############################################################################
mkdir -p "$EFS_ROOT"

if mountpoint -q "$EFS_ROOT"; then
  umount "$EFS_ROOT"
fi
mount -t efs -o tls "${EFS_ID}:/" "$EFS_ROOT"

# 영구 항목. 같은 마운트 포인트의 오래된 줄은 먼저 제거합니다.
touch /etc/fstab
sed -i "\|[[:space:]]${EFS_ROOT}[[:space:]]|d" /etc/fstab
echo "${EFS_ID}:/ ${EFS_ROOT} efs _netdev,tls 0 0" >> /etc/fstab

###############################################################################
# 3) 체크아웃의 mnt/ 를 EFS 로 동기화
#
#    --delete 를 쓰면 EFS 에만 있는 .oefj 가 지워지므로 쓰지 않습니다.
#    GCP 의 bind mount 와 달리 복사이므로, mnt/ 를 고칠 때마다 다시 실행합니다.
###############################################################################
rsync -av --no-perms --no-owner --no-group \
  "$GIT_MNT/" "$EFS_ROOT/"

###############################################################################
# 4) 결과
###############################################################################
echo
echo "============================================================"
echo "EFS ready"
echo "============================================================"
echo "Git source  : $GIT_MNT"
echo "EFS mount   : $EFS_ROOT"
echo "File system : $EFS_ID"
echo "Pod subpath : /batch_eks/l2/rsvp  -> /home/jupyter"
echo "Mode        : Pod 에서는 읽기 전용 (PV readOnly)"
echo "Port        : TCP 2049 (sg-l2comm-efs 에서 허용)"
echo "============================================================"
echo
echo "Verify:"
echo "  findmnt $EFS_ROOT"
echo "  ls $EFS_ROOT/batch_eks/l2/rsvp/GP_L2RSVP_001_1/python"
echo
echo "mnt/ 를 수정한 뒤에는 이 스크립트를 다시 실행해 동기화하십시오."
echo "자격증명 파일은 EFS 안에만 둡니다:"
echo "  $EFS_ROOT/batch_eks/l2/rsvp/.oefj"
