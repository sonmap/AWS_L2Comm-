#!/usr/bin/env bash
set -euo pipefail

# OCR-compatible input contract (GCP 원본과 동일)
# $1  FROM_BASE_YMD
# $2  TO_BASE_YMD
# $3  CURR_YMD
# $4  CURR_TIME
# $5  VM_GPU
# $6  VM_CPU
# $7  VM_MEM
# $8  WORKING_DIRECTORY  (path inside the Pod; normally /home/...)
# $9  PROGRAM_PATH       (for example: python)
# $10... PROGRAM_PARAM

if [[ $# -lt 9 ]]; then
  cat <<'USAGE'
Usage:
  run-eks.sh FROM_BASE_YMD TO_BASE_YMD CURR_YMD CURR_TIME \
    VM_GPU VM_CPU VM_MEM WORKING_DIRECTORY PROGRAM_PATH [PROGRAM_PARAM...]

Example:
  DOCKER_IMAGE=444455556666.dkr.ecr.ap-northeast-2.amazonaws.com/ar-l2comm-python/python-athena-batch:v1 \
  /ssw/dlk/run-eks.sh \
    20261008 20261008 20261008 180000 \
    0 4 16 \
    /home/jupyter/GP_L2RSVP_001_1/python \
    python athena_auth_smoke.py
USAGE
  exit 1
fi

FROM_BASE_YMD="$1"
TO_BASE_YMD="$2"
CURR_YMD="$3"
CURR_TIME="$4"
VM_GPU="$5"
VM_CPU="$6"
VM_MEM="$7"
WORKING_DIRECTORY="$8"
PROGRAM_PATH="$9"
shift 9
PROGRAM_PARAM=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_EKS="${SCRIPT_DIR}/client_eks"

DOCKER_IMAGE="${DOCKER_IMAGE:-}"
if [[ -z "${DOCKER_IMAGE}" ]]; then
  echo "ERROR: DOCKER_IMAGE 가 비어 있습니다." >&2
  echo "       ECR 레지스트리는 계정마다 다르므로 기본값을 두지 않습니다." >&2
  echo "       예: DOCKER_IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/ar-l2comm-python/python-athena-batch:v1" >&2
  echo "       aws/00-env.sh 를 source 하면 IMAGE_URI 로 확인할 수 있습니다." >&2
  exit 1
fi

NAMESPACE="${NAMESPACE:-l2comm-batch}"
PROGRAM_ID="${PROGRAM_ID:-l2comm-${CURR_YMD}-${CURR_TIME}}"

quote_cmd() {
  printf '%q ' "$@"
}

PARAM_CMD="$(quote_cmd "${PROGRAM_PARAM[@]}")"
SHELL_COMMAND="cd $(printf '%q' "$WORKING_DIRECTORY") && $(printf '%q' "$PROGRAM_PATH") $PARAM_CMD"

echo "FROM_BASE_YMD    : $FROM_BASE_YMD"
echo "TO_BASE_YMD      : $TO_BASE_YMD"
echo "CURR_YMD         : $CURR_YMD"
echo "CURR_TIME        : $CURR_TIME"
echo "VM_GPU           : $VM_GPU"
echo "VM_CPU           : $VM_CPU"
echo "VM_MEM           : $VM_MEM"
echo "WORKING_DIRECTORY: $WORKING_DIRECTORY"
echo "PROGRAM_PATH     : $PROGRAM_PATH"
echo "PROGRAM_PARAM    : ${PROGRAM_PARAM[*]:-}"
echo "DOCKER_IMAGE     : $DOCKER_IMAGE"
echo "NAMESPACE        : $NAMESPACE"
echo

exec "$CLIENT_EKS" \
  --program-id "$PROGRAM_ID" \
  --docker-image "$DOCKER_IMAGE" \
  --gpu "$VM_GPU" \
  --cpu "$VM_CPU" \
  --mem-gb "$VM_MEM" \
  --shell-command "$SHELL_COMMAND" \
  --namespace "$NAMESPACE"
