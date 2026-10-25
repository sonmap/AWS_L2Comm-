# AWS_L2Comm EC2 실행 스크립트

작업 디렉터리: `~/AWS_L2Comm-`.

| 파일 | 역할 |
|---|---|
| `install-vm.sh` | `/ssw/dlk` 최초 심볼릭 링크 생성. 기존 다른 링크는 자동 교체하지 않음 |
| `setup-efs.sh` | EFS 를 `/srv/l2comm-efs` 에 마운트하고 현재 체크아웃의 `mnt/` 를 rsync |
| `client_common` | EFS RSVP 경로, `/home/jupyter`, `.oefj`, PV/PVC 기본값 |
| `run-eks.sh` | 날짜·리소스·작업 경로·프로그램 인자 전달 |
| `client_eks` | PV/PVC·Pod 생성 및 대기·로그·성공 정리 |

```bash
cd ~/AWS_L2Comm-
chmod +x ssw/dlk/*.sh ssw/dlk/client_eks
chmod +x mnt/batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh
```

기존 링크 재연결, EFS 동기화, 자격증명 확인, DRY_RUN 및 실제 실행은
[RUNBOOK](../../docs/RUNBOOK.md) §10~11을 따릅니다.
공통 run-eks.sh 를 직접 호출할 때는 Pod 작업 경로를 지정합니다.
RSVP 래퍼는 기존 `/mnt/batch_eks/l2/rsvp/...`(및 GCP 시절 `/mnt/batch_gke/...`)
인자를 `/home/jupyter/...` 로 변환합니다.
Job·KEEP_JOB·debug-eks.sh·CloudWatch Logs 자동 폴백은 지원하지 않습니다.

GCP 원본과의 차이: `run-eks.sh` 는 기본 DOCKER_IMAGE 를 두지 않습니다.
ECR 레지스트리 주소가 계정마다 다르기 때문입니다. 항상 명시하십시오.
