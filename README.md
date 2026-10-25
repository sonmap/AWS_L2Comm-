# AWS_L2Comm

[`Gcp_Managed_GKE_L2Comm03-01`](https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03-01)
의 GKE Autopilot 구성을 AWS 로 전환한 저장소입니다.

GKE Autopilot → **EKS Auto Mode**, BigQuery → **S3 + Glue + Athena**,
VM NFS → **EFS**, gcloud 스크립트 → **aws CLI 스크립트**.
실행 흐름과 9개 인자 계약, 번호 체계는 원본 그대로 유지했습니다.

## 시작

```bash
cd ~
git clone https://github.com/sonmap/AWS_L2Comm-.git
cd ~/AWS_L2Comm-
chmod +x aws/*.sh ssw/dlk/*.sh ssw/dlk/client_eks
chmod +x mnt/batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh
```

이미 내려받았다면 해당 디렉터리에서 `git pull --ff-only origin main` 을 실행합니다.
**먼저 `aws/00-env.sh` 의 계정 ID 3개와 `VPC_NAME` 을 실제 값으로 바꾸십시오.**
단계별 실행·확인은 [RUNBOOK](docs/RUNBOOK.md) 을 따릅니다.

## 구성

| 경로 | 역할 |
|---|---|
| `aws/` | IAM·네트워크·EKS·EFS·CodeBuild 구축 |
| `app/`, `codebuild/` | 이미지 소스와 빌드 정의 |
| `ssw/dlk/client_common` | RSVP EFS·마운트·자격증명 경로 기본값 |
| `ssw/dlk/client_eks` | PV/PVC 와 Pod 생성, 완료 대기 및 정리 |
| `ssw/dlk/run-eks.sh` | 공통 배치 실행 진입점 |
| `mnt/batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh` | RSVP 래퍼, EC2 경로를 Pod 경로로 변환 |
| `mnt/batch_eks/l2/rsvp/GP_L2RSVP_001_1/python/athena_auth_smoke.py` | 키 인증으로 Athena SELECT 검사 |
| `mnt/python/` | 별도 조회 샘플. 기본 RSVP 동기화에는 포함되지 않음 |
| `helm/`, `k8s/` | 참고용 매니페스트. RSVP 표준 실행 절차와 별도 |

## 실행 흐름

EC2 RSVP 래퍼 → 공통 run-eks.sh → client_eks → PV/PVC → EKS Auto Mode Pod
→ EFS Python → Athena SELECT → 로그 출력 → 성공 Pod 삭제.
EventBridge Scheduler 와 Step Functions 는 이 실행 경로에서 사용하지 않습니다.

| 항목 | 현재 값 |
|---|---|
| 체크아웃 | `~/AWS_L2Comm-` |
| CodeConnections 연결 | `github-l2comm` |
| CodeBuild 프로젝트 | `cb-l2comm-python-image` |
| EFS 마운트 | `<repo>/mnt` → `/srv/l2comm-efs` (rsync 동기화) |
| Pod 에서 사용하는 EFS 하위 경로 | `/batch_eks/l2/rsvp` |
| Pod 마운트 | `/home/jupyter` |
| 인증 파일 | EC2 `/srv/l2comm-efs/batch_eks/l2/rsvp/.oefj` → Pod `/home/jupyter/.oefj` |
| PV / PVC | `l2comm-rsvp-pv` / `l2comm-rsvp-pvc` |

키 파일은 EC2 에서 별도로 준비하며 Git 에 반영하지 않습니다.
현재 클라이언트는 Pod 방식이며 Job TTL, KEEP_JOB, CloudWatch Logs 자동 폴백을
지원하지 않습니다.

설계는 [DESIGN](docs/DESIGN.md), 파일 역할은 [STRUCTURE](docs/STRUCTURE.md),
**GCP 원본과의 대응표와 1:1 이 아닌 지점**은 [MIGRATION](docs/MIGRATION.md) 을
참고하십시오.

Athena 는 모든 Python 샘플에서 `.oefj` 자격증명을 명시적으로 읽어 인증합니다.
`client_eks` 는 ServiceAccount 에 IAM 어노테이션을 설정하지 않습니다.
Pod 의 Kubernetes 실행에는 ServiceAccount 가 계속 필요하지만 Athena 인증 주체는
자격증명 파일의 IAM 주체입니다.

> GCP 원본의 `.oefj` 는 서비스 계정 JSON 키였습니다. 여기서는 같은 경로에
> AWS 공유 자격증명(INI) 파일을 둡니다. 형식이 다르므로 그대로 복사하면
> 동작하지 않습니다. [MIGRATION §4-4](docs/MIGRATION.md) 를 보십시오.
