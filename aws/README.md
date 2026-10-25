# aws/ 구축 스크립트

GCP 원본 `gcloud/` 의 번호 체계를 그대로 유지했습니다.
대응표는 [docs/MIGRATION.md](../docs/MIGRATION.md) §3.

| 순서 | 스크립트 | 프로파일 | 하는 일 |
|---|---|---|---|
| - | `00-env.sh` | - | 공통 환경변수. 나머지가 source 합니다 |
| 1 | `00-bootstrap.sh` | Owner | 서비스 연결 역할, 관리 EC2 역할, 배포 주체 정책 |
| 2 | `10-network.sh` | Owner | VPC 보조 CIDR, 서브넷 4개, RAM 공유, VPC 엔드포인트 |
| 3 | `11-securitygroup.sh` | Owner | 보안그룹 3종 (cluster / efs / mgmt) |
| 4 | `05-check-permissions.sh` | 배포 주체 | 20·30 단계 권한 사전 점검 |
| 5 | `20-source-connection.sh` | 배포 주체 | GitHub CodeConnections (콘솔 승인 필요) |
| 6 | `30-platform.sh` | 배포 주체 | ECR·IAM·S3/Glue/Athena·CodeBuild·EKS·EFS·Pod Identity |
| - | `99-verify.sh` | 조회 | 전체 자원 상태 점검 |
| - | `90-teardown.sh` | 배포 주체 | 역순 삭제. 재테스트용으로 쓰지 마십시오 |

실행 전 반드시 `00-env.sh` 의 아래 값을 실제 환경으로 바꾸십시오.

```bash
WORKLOAD_ACCOUNT   # EKS / CodeBuild 계정 ID
NETWORK_ACCOUNT    # VPC / ECR 계정 ID
DATA_ACCOUNT       # S3 / Glue / Athena 계정 ID
VPC_NAME           # 기존 VPC 의 Name 태그
OWNER_PROFILE      # aws configure 프로파일명
ADMIN_PROFILE      # aws configure 프로파일명
ADMIN_PRINCIPAL_NAME  # 배포 주체 IAM 사용자/역할 이름
```

세 계정 ID 가 모두 같으면 단일 계정 구성으로 동작합니다.
RAM 공유와 ECR 크로스 계정 정책 단계는 자동으로 생략됩니다.

모든 스크립트는 멱등합니다. 이미 존재하는 자원은 `SKIP` 을 출력하고 넘어갑니다.
각 스크립트는 시작 시 실행 프로파일을 검증하고, 틀리면 전환 방법을 안내하며
중단합니다. 우회가 필요하면 `SKIP_PROFILE_CHECK=1` 을 앞에 붙입니다.
