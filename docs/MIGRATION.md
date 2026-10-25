# GCP L2Comm03-01 → AWS L2Comm 전환

원본: [`sonmap/Gcp_Managed_GKE_L2Comm03-01`](https://github.com/sonmap/Gcp_Managed_GKE_L2Comm03-01)

GKE Autopilot + BigQuery + VM NFS 구성을
EKS Auto Mode + Athena/Glue/S3 + EFS 로 옮겼습니다.
실행 흐름(관리 VM → RSVP 래퍼 → 공통 run → 클라이언트 → Pod)과
9개 필수 인자 계약, 파일 배치, 번호 체계는 그대로 유지했습니다.

---

## 1. 서비스 매핑

| 영역 | GCP | AWS | 비고 |
|---|---|---|---|
| 컴퓨트 | GKE Autopilot | **EKS Auto Mode** | 노드 관리 없음. 가장 가까운 대응물 |
| 컨테이너 레지스트리 | Artifact Registry | **ECR** | 크로스 계정은 저장소 정책으로 |
| 빌드 | Cloud Build + 2nd-gen Connection + Trigger | **CodeBuild + CodeConnections + Webhook** | 저장소 개별 등록 단계가 없음 |
| 분석 | BigQuery dataset/table | **S3 + Glue Catalog + Athena** | 서버리스 쿼리 과금 모델이 가장 유사 |
| 공유 파일시스템 | 관리 VM 의 nfs-kernel-server | **EFS + EFS CSI 드라이버** | export → sync 로 역할이 바뀜 |
| Pod 자격증명 | Workload Identity (KSA→GSA 어노테이션) | **EKS Pod Identity** | 어노테이션 불필요. Association 1건 |
| 네트워크 공유 | Shared VPC (서비스 프로젝트 연결) | **AWS RAM 서브넷 공유** | 단일 계정이면 불필요 |
| 사설 egress | Private Google Access | **VPC 엔드포인트 12종** | 서비스별로 개별 생성 필요 |
| 방화벽 | VPC Firewall Rule (target tag) | **Security Group (source SG)** | 태그 → SG 참조로 |
| 조직 경계 | 프로젝트 3개 | **계정 3개** | 단일 계정 PoC 도 지원 |
| 리전 | `asia-northeast3` | `ap-northeast-2` | 둘 다 서울 |

## 2. 리소스 이름 대응

| GCP | AWS |
|---|---|
| `gcp-prod-edp-edge-509423` (Edge) | `WORKLOAD_ACCOUNT` |
| `gcp-prod-edp-hub-vpchost` (Host) | `NETWORK_ACCOUNT` |
| `pjt-c-admin` (Data) | `DATA_ACCOUNT` |
| `admin@sonmap.net` (Owner) | `OWNER_PROFILE` = `l2comm-owner` |
| `cho@sonmap.net` (배포 주체) | `ADMIN_PROFILE` = `l2comm-admin` |
| `vpc-prod-edp-hub` | `vpc-prod-edp-hub` (이름 유지) |
| `subnet-prod-edp-l2comm-gke-an3` | `subnet-prod-edp-l2comm-eks-{a,c}` + `-infra-{a,c}` |
| `gke-l2comm-batch-an3` | `eks-l2comm-batch-an2` |
| `sa-l2comm-gke` | `role-l2comm-eks` |
| `ksa-l2comm-batch` | `ksa-l2comm-batch` (이름 유지) |
| `ar-l2comm-python/python-bq-batch:v1` | `ar-l2comm-python/python-athena-batch:v1` |
| `trg-l2comm03-01-python-image` | `cb-l2comm-python-image` |
| `github-l2comm` (CB Connection) | `github-l2comm` (CodeConnections) |
| `pjt-c-admin.dlk_sample.gcp_region_inventory` | `dlk_sample.aws_region_inventory` (Glue) |
| `l2comm-rsvp-pv` / `l2comm-rsvp-pvc` | 이름 유지 |
| `/srv/l2comm-nfs` | `/srv/l2comm-efs` |

## 3. 파일 대응

| GCP | AWS | 변경 요지 |
|---|---|---|
| `gcloud/00-env.sh` | `aws/00-env.sh` | `require_account` → `require_profile`, `ok_if_exists` 패턴 교체 |
| `gcloud/00-bootstrap.sh` | `aws/00-bootstrap.sh` | API 활성화 개념 없음 → SLR + IAM 정책만 |
| `gcloud/05-check-permissions.sh` | `aws/05-check-permissions.sh` | `test-iam-permissions` → `simulate-principal-policy` |
| `gcloud/10-network.sh` | `aws/10-network.sh` | 보조 CIDR + 서브넷 4개 + RAM + VPC 엔드포인트 |
| `gcloud/11-firewall.sh` | `aws/11-securitygroup.sh` | 방화벽 규칙 → 보안그룹 3종 |
| `gcloud/20-source-connection.sh` | `aws/20-source-connection.sh` | 저장소 등록 단계 없음. 콘솔 핸드셰이크 안내 |
| `gcloud/30-platform.sh` | `aws/30-platform.sh` | + EFS, EFS CSI 애드온, Access Entry |
| `gcloud/90-teardown.sh` | `aws/90-teardown.sh` | + EFS 마운트 타깃 선삭제 |
| `gcloud/99-verify.sh` | `aws/99-verify.sh` | `bq query` → Athena 폴링 |
| `cloudbuild/cloudbuild.yaml` | `codebuild/buildspec.yml` | 명시적 `docker push` 필요 |
| `app/main.py` | `app/main.py` | Compute Regions → `describe_regions`, BQ load → S3+Glue |
| `ssw/dlk/client_gke` | `ssw/dlk/client_eks` | PV `nfs:` → `csi: efs.csi.aws.com` |
| `ssw/dlk/setup-nfs-server.sh` | `ssw/dlk/setup-efs.sh` | export → EFS 마운트 + rsync |
| `ssw/dlk/run-gke.sh` | `ssw/dlk/run-eks.sh` | 인자 계약 동일. 기본 이미지 제거 |
| `mnt/batch_gke/...` | `mnt/batch_eks/...` | 디렉터리명만 변경. 구 경로 인자도 수용 |
| `bq_auth_smoke.py` | `athena_auth_smoke.py` | 상수 SELECT 를 Athena 로 |
| `mnt/python/bq_sample.py` | `mnt/python/athena_sample.py` | 동일 |

## 4. 설계상 1:1 이 아닌 부분

이 다섯 가지는 플랫폼 차이 때문에 그대로 옮길 수 없었습니다.

### 4-1. Pod Secondary Range 가 없습니다

GKE 는 서브넷에 Pod 전용 2차 대역(`100.64.128.0/19`)을 붙였습니다.
AWS VPC CNI 에는 이 모델이 없고 Pod 이 노드 서브넷 IP 를 직접 받습니다.
그래서 `100.64.128.0/19` 를 **VPC 보조 CIDR** 로 붙이고 그 안에 EKS
노드/Pod 서브넷을 뒀습니다. 기존 `10.252.1.0/24` 는 EFS 마운트 타깃과
관리 EC2 용 서브넷으로 남겼습니다.

> 커스텀 네트워킹(ENIConfig)으로 노드와 Pod 대역을 분리하는 방법이
> 있지만 EKS Auto Mode 는 이를 지원하지 않습니다.

### 4-2. Control Plane CIDR 을 예약하지 않습니다

GKE 는 `--master-ipv4-cidr=10.254.5.0/28` 로 Control Plane 대역을
따로 잡았습니다. EKS 는 Control Plane ENI 를 지정한 서브넷에 직접
만들므로 예약 대역이 없습니다. `master-authorized-networks` 대신
`endpointPublicAccess=false` + 보안그룹으로 제어합니다.

따라서 GCP 의 `fw-l2comm-master-to-node`(tcp:10250 등) 규칙에 해당하는
작업이 없습니다. 클러스터 보안그룹의 self 규칙 하나로 끝납니다.
**konnectivity 트러블슈팅 항목도 그대로 사라집니다.**

### 4-3. NFS export → EFS sync

GCP 는 `mount --bind <repo>/mnt /srv/l2comm-nfs` 로 **체크아웃을 직접**
노출했으므로 `git pull` 즉시 Pod 에 반영됐습니다.
EFS 는 별도 파일시스템이라 복사가 필요합니다. `setup-efs.sh` 가
`rsync` 를 돌립니다. **`mnt/` 를 고칠 때마다 다시 실행해야 합니다.**

`--delete` 는 쓰지 않습니다. EFS 에만 있는 `.oefj` 가 지워지기 때문입니다.

### 4-4. 자격증명 파일 형식이 바뀝니다

경로 계약(`/home/jupyter/.oefj`)과 환경변수 이름(`SA_KEY_PATH`)은
유지했지만 내용이 다릅니다.

| | GCP | AWS |
|---|---|---|
| 형식 | 서비스 계정 JSON 키 | 공유 자격증명 INI |
| 읽는 환경변수 | `GOOGLE_APPLICATION_CREDENTIALS` | `AWS_SHARED_CREDENTIALS_FILE` + `AWS_PROFILE` |

AWS 파일 예시 (프로파일 이름은 `SA_KEY_PROFILE`, 기본 `l2comm`):

```ini
[l2comm]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

> 장기 액세스 키는 권장되지 않습니다. 이 구성은 GCP 원본의
> "키 파일을 명시적으로 읽는다"는 계약을 유지하기 위한 것입니다.
> 키 없이 가도 된다면 `.oefj` 검사를 빼고 Pod Identity 만 쓰십시오.
> `30-platform.sh` 가 이미 Association 을 만들어 둡니다.

### 4-5. CodeConnections 는 CLI 로 완결되지 않습니다

`gcloud builds connections` 는 Connection 아래에 저장소를 등록하는
2단계 모델이었습니다. CodeConnections 는 GitHub 계정/조직당 1개만
만들면 되고 저장소 지정은 CodeBuild 프로젝트에서 합니다.

다만 **생성 직후 상태가 `PENDING`** 이고, 브라우저에서 GitHub 앱
설치를 한 번 승인해야 `AVAILABLE` 이 됩니다. CLI 로 끝낼 수 없습니다.
`20-source-connection.sh` 가 이 상태를 감지하면 콘솔 URL 을 출력하고
중단합니다.

## 5. 옮기지 않은 것

| 항목 | 사유 |
|---|---|
| Workflows / Cloud Scheduler | GCP 원본 런타임 경로에서도 쓰지 않았음. 정기 실행은 EC2 crontab |
| Infrastructure Manager | GCP 원본에서 선택사항(`CREATE_INFRAMGR=false`)이었음 |
| `gke-gcloud-auth-plugin` | `aws eks update-kubeconfig` 가 토큰을 직접 발급 |
| Cloud NAT | ECR/S3/Athena 를 VPC 엔드포인트로 접근하므로 불필요 |
| `bq add-iam-policy-binding` 폴백 | Glue 는 allowlist 제약이 없어 분기 불필요 |

## 6. Redshift 로 바꾸려면

Athena 대신 Redshift Serverless 를 쓰려면 다음만 교체하면 됩니다.

1. `00-env.sh`: `ATHENA_WORKGROUP` → `REDSHIFT_WORKGROUP` / `REDSHIFT_NAMESPACE`
2. `30-platform.sh` §4: `athena create-work-group` →
   `redshift-serverless create-namespace` + `create-workgroup` (서브넷 지정)
3. `athena_auth_smoke.py`: `boto3.client("athena")` →
   `boto3.client("redshift-data")` 의 `execute_statement` / `describe_statement`
4. `app/main.py`: Glue 테이블 등록 대신 `COPY FROM s3://...` 실행
5. `10-network.sh`: `athena`/`glue` 엔드포인트 → `redshift-data` 엔드포인트
6. IAM: `athena:*` / `glue:*` → `redshift-data:*` + `redshift-serverless:GetCredentials`

Redshift Serverless 는 VPC 내부에 배치되므로 엔드포인트 비용 대신
워크그룹 RPU 과금이 발생합니다. 배치 빈도가 낮으면 Athena 가 저렴합니다.

## 7. 전환 시 확인 순서

기존 GCP 구성을 삭제할 필요가 없습니다. 두 환경은 독립입니다.

1. `aws/00-env.sh` 의 계정 ID 3개와 `VPC_NAME` 을 실제 값으로 교체
2. RUNBOOK §4~5 로 IAM·네트워크 구성 (Owner 프로파일)
3. RUNBOOK §6 권한 사전 점검 (배포 주체)
4. RUNBOOK §7 CodeConnections 승인 — **브라우저 작업 필요**
5. RUNBOOK §8 플랫폼 구성 (EKS 생성에 10~15분)
6. RUNBOOK §9 이미지 빌드
7. RUNBOOK §10 EFS 동기화와 `.oefj` 배치
8. RUNBOOK §11 DRY_RUN=1 로 매니페스트 확인 후 DRY_RUN=0

`90-teardown.sh` 는 공유 자원을 삭제하므로 단순 재테스트용으로
실행하지 않습니다.
