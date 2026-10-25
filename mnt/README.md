# AWS_L2Comm EFS 소스

EFS 동기화 원본은 `~/AWS_L2Comm-/mnt` 입니다.
RSVP 클라이언트는 그 아래 `/batch_eks/l2/rsvp` 를 `/home/jupyter` 에 마운트합니다.

| 경로 | 용도 |
|---|---|
| `batch_eks/l2/rsvp/GP_L2RSVP_001_1/python/athena_auth_smoke.py` | Pod에서 실행하는 인증 검사 |
| `batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh` | EC2에서 실행하는 RSVP 래퍼 |
| `python/athena_sample.py` | 별도 조회 샘플. 기본 RSVP 동기화에는 포함되지 않음 |

`.oefj` 는 EFS 의 `batch_eks/l2/rsvp/` 에 EC2 에서 별도로 준비하며 Git 에 올리지 않습니다.
GCP 원본과 달리 EFS 는 bind mount 가 아니라 rsync 복사본입니다.
이 디렉터리를 수정한 뒤에는 `sudo bash /ssw/dlk/setup-efs.sh` 를 다시 실행하십시오.
실행은 [RUNBOOK](../docs/RUNBOOK.md) §10~11을 따릅니다.
