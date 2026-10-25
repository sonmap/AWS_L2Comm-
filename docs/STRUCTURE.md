# AWS L2Comm 저장소 구조

| 경로 | 실행 위치 | 내용 |
|---|---|---|
| `aws/00-env.sh` | EC2 에서 source | 계정·CIDR·역할·저장소·CodeBuild 설정 |
| `aws/00-bootstrap.sh` | Owner | 서비스 연결 역할과 IAM |
| `aws/10-network.sh` | Owner | 보조 CIDR·서브넷·RAM 공유·VPC 엔드포인트 |
| `aws/11-securitygroup.sh` | Owner | EFS 2049 및 EKS API 통신 |
| `aws/05-check-permissions.sh` | 배포 주체 | 권한 점검 |
| `aws/20-source-connection.sh` | 배포 주체 | GitHub CodeConnections |
| `aws/30-platform.sh` | 배포 주체 | ECR·IAM·S3/Glue/Athena·CodeBuild·EKS·EFS·Pod Identity |
| `aws/99-verify.sh` | 조회 주체 | 자원과 Pod 상태 확인 |
| `aws/90-teardown.sh` | 배포 주체 | 공유 인프라 삭제용. 재테스트 시 실행 불필요 |
| `app/` | CodeBuild / Pod | 이미지 내부 `/app/main.py` 적재 샘플 |
| `codebuild/buildspec.yml` | CodeBuild | 이미지 빌드와 ECR 푸시 |
| `ssw/dlk/install-vm.sh` | EC2 | `/ssw/dlk` 심볼릭 링크 최초 생성 |
| `ssw/dlk/setup-efs.sh` | EC2 sudo | EFS 마운트 후 현재 체크아웃의 `mnt/` 동기화 |
| `ssw/dlk/client_common` | EC2 에서 source | RSVP 환경변수 |
| `ssw/dlk/run-eks.sh` | EC2 | 9개 필수 인자 및 이후 프로그램 인자를 client_eks 에 전달 |
| `ssw/dlk/client_eks` | EC2 | PV/PVC·Pod YAML 생성, apply, Succeeded 대기, 로그, 성공 Pod 삭제 |
| `mnt/batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh` | EC2 | RSVP 실행 래퍼 |
| `mnt/batch_eks/l2/rsvp/GP_L2RSVP_001_1/python/athena_auth_smoke.py` | Pod | Athena 키 인증 검사 |
| `mnt/python/athena_sample.py` | Pod (별도 동기화 설정 필요) | 기존 테이블 조회 |
| `helm/l2comm-batch/`, `k8s/debug-pod.yaml` | 참고 | RSVP 표준 실행과 별도 설정 |
| `docs/RUNBOOK.md` | 사람 | 단계별 실행과 기대 결과 |
| `docs/MIGRATION.md` | 사람 | GCP 원본과의 대응표, 1:1 이 아닌 지점 |

RSVP 마운트 매핑:

| EC2 (EFS) | Pod |
|---|---|
| `/srv/l2comm-efs/batch_eks/l2/rsvp/` | `/home/jupyter/` |
| `.../rsvp/.oefj` | `/home/jupyter/.oefj` |
| `.../rsvp/GP_L2RSVP_001_1/python/` | `/home/jupyter/GP_L2RSVP_001_1/python/` |

기본 EFS 하위 경로가 RSVP 이므로 `mnt/python/` 는 이 마운트에 나타나지 않습니다.

GCP 원본과 달리 EFS 는 체크아웃의 bind mount 가 아니라 복사본입니다.
`mnt/` 를 수정하거나 `git pull` 한 뒤에는 `sudo bash /ssw/dlk/setup-efs.sh` 를
다시 실행해야 Pod 에 반영됩니다. 상세는 RUNBOOK §10-2.

기존 `/ssw/dlk` 링크를 바꾼 뒤에도 같습니다.
`install-vm.sh` 는 `REPOINT=true` 를 지원하지 않으며, 상세 절차는 RUNBOOK §10-1 을 따릅니다.
성공한 배치는 Pod 을 삭제합니다. 실패 Pod 은 이름을 확인한 뒤 수동 점검합니다.
