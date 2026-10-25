# AWS L2Comm 설계

## 계정 및 네트워크

| 항목 | 값 |
|---|---|
| Network / ECR | `NETWORK_ACCOUNT` (구 `gcp-prod-edp-hub-vpchost`) |
| Workload / EKS / CodeBuild | `WORKLOAD_ACCOUNT` (구 `gcp-prod-edp-edge-509423`) |
| Data (S3 / Glue / Athena) | `DATA_ACCOUNT` (구 `pjt-c-admin`) |
| VPC | `vpc-prod-edp-hub` |
| EKS 서브넷 | `subnet-prod-edp-l2comm-eks-a` `100.64.128.0/20` (AZ a) |
| | `subnet-prod-edp-l2comm-eks-c` `100.64.144.0/20` (AZ c) |
| 관리/EFS 서브넷 | `subnet-prod-edp-l2comm-infra-a` `10.252.1.0/25` (AZ a) |
| | `subnet-prod-edp-l2comm-infra-c` `10.252.1.128/25` (AZ c) |
| VPC 보조 CIDR | `100.64.128.0/19` |
| Service 대역 | EKS 관리 대역 (서브넷에 별도 생성하지 않음) |
| 클러스터 | `eks-l2comm-batch-an2`, `ap-northeast-2`, Auto Mode |

세 계정이 같은 값이어도 동작합니다. 단일 계정 PoC 라면 `00-env.sh` 에서
세 값을 모두 같게 두면 RAM 공유와 ECR 저장소 정책 단계가 자동으로 생략됩니다.

Pod 은 노드 서브넷 IP 를 직접 받습니다. GKE 의 Pod Secondary Range 개념이
AWS VPC CNI 에 없기 때문이며, 그래서 `100.64.128.0/19` 를 통째로 보조 CIDR
로 붙여 Pod 밀도를 흡수합니다. 자세한 사정은 [MIGRATION](MIGRATION.md) §4-1.

## 빌드 및 실행

CodeConnections 의 `github-l2comm` 연결과 CodeBuild 프로젝트
`cb-l2comm-python-image` 가 `app/`, `codebuild/`, `aws/` 변경을 빌드합니다.
이미지는 NETWORK 계정의 `ar-l2comm-python/python-athena-batch:v1` 에 저장됩니다.

실행은 관리 EC2 → RSVP run-eks.sh → 공통 run-eks.sh → client_eks → EKS Pod 입니다.
Pod 은 EFS 의 `/batch_eks/l2/rsvp` 를 `/home/jupyter` 에 읽기 전용 마운트합니다.
인증 샘플은 `/home/jupyter/.oefj` 를 명시적으로 읽습니다.
`role-l2comm-eks` 의 Pod Identity 연결과 키 인증 검사는 구분합니다.
`client_eks` 는 ServiceAccount 에 IAM 어노테이션을 설정하지 않습니다.
boto3 는 `.oefj` 를 `AWS_SHARED_CREDENTIALS_FILE` 로 읽어 프로파일을 명시적으로 씁니다.

DRY_RUN 기본값은 1입니다. 0일 때 PV/PVC 와 Pod 을 적용합니다.
클라이언트는 최대 3600초 동안 Succeeded 를 기다리고 로그를 출력합니다.
성공 Pod 은 삭제하고 실패 Pod 은 남깁니다. Job 재시도나 TTL 은 없습니다.

## 저장소 구조

EFS 는 관리형이므로 관리 EC2 가 NFS 서버가 아닙니다.
`setup-efs.sh` 는 EFS 를 `/srv/l2comm-efs` 에 마운트하고 체크아웃의 `mnt/` 를
`rsync` 로 올립니다. GCP 의 bind mount 와 달리 복사이므로
**`mnt/` 를 수정하면 다시 실행해야 Pod 에 반영됩니다.**

EFS CSI 드라이버는 Auto Mode 기본 제공이 아니라 애드온으로 설치합니다
(`30-platform.sh` §8). 드라이버 자체도 Pod Identity 로 EFS API 를 조회합니다.

## 계정과 접근

Owner 프로파일 `l2comm-owner` 는 IAM·VPC·보안그룹을 관리합니다.
배포 주체 `l2comm-admin` 은 권한 점검 이후 플랫폼을 구성합니다.
관리 EC2 의 kubectl 주체가 EKS API 에 Pod 과 PV/PVC 를 만들 권한이 있어야 합니다.

EKS 접근 제어는 `authenticationMode=API` 의 Access Entry 로 합니다.
`aws-auth` ConfigMap 을 편집하지 않습니다. `30-platform.sh` 가 배포 주체와
관리 EC2 역할에 `AmazonEKSClusterAdminPolicy` 를 연결합니다.

키 파일의 IAM 주체는 Athena 쿼리 실행과 Glue 카탈로그 조회 권한이 필요합니다.
`athena_auth_smoke.py` 는 테이블 없이 상수 SELECT 만 실행합니다.
`app/main.py` 는 동일한 `.oefj` 로 EC2 리전을 조회해 S3 에 적재하고
Glue 테이블을 갱신하는 별도 샘플입니다.

키 파일은 Git 관리 대상에서 제외하며 EC2 안에서만 준비합니다.
Private 엔드포인트, EFS TCP 2049, 이미지 Pull 접근은 RUNBOOK 에서 순서대로 확인합니다.

## 사설 egress

NAT Gateway 없이 동작하도록 VPC 엔드포인트를 둡니다.
GCP 의 Private Google Access 한 줄에 해당하는 구성이 AWS 에서는 12개입니다.

| 유형 | 서비스 |
|---|---|
| Gateway | `s3` |
| Interface | `ecr.api`, `ecr.dkr`, `sts`, `logs`, `eks`, `eks-auth`, `elasticfilesystem`, `athena`, `glue`, `ssm`, `ssmmessages`, `ec2messages` |

`eks-auth` 가 빠지면 Pod Identity 가 동작하지 않습니다.
`ssm*` 3종은 관리 EC2 에 공인 IP 없이 Session Manager 로 들어가기 위한 것입니다.
공인 인터넷 egress 가 추가로 필요하면 NAT Gateway 를 별도로 구성하십시오.
