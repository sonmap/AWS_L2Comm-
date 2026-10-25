# AWS_L2Comm RUNBOOK (Ubuntu EC2 작업 기준)

VPC 내부 Ubuntu EC2 한 대에서 `git clone` 부터 배치 실행·결과 확인까지
전부 수행하는 절차입니다. 위에서부터 순서대로 복사해 실행하십시오.

각 단계는 **실행 → 확인 → 기대 결과** 구성입니다.
기대 결과가 나오지 않으면 다음 단계로 넘어가지 말고 §13(오류 대응)를 보십시오.

GCP 원본 RUNBOOK 과의 대응은 [MIGRATION](MIGRATION.md) 을 참고하십시오.

---

## 프로파일 분리 원칙

| 프로파일 | 용도 | 사용 단계 |
|---|---|---|
| `l2comm-owner` | **IAM 부여 + 네트워크/보안그룹 관리** | §4, §5 |
| `l2comm-admin` | 배포·운영 주체 | §6 이후 전부 (§6-2 권한 사전 점검 필수) |

각 스크립트는 시작 시 실행 프로파일을 검증하고, 틀리면 전환 방법을 안내하며 중단합니다.
우회가 필요하면 `SKIP_PROFILE_CHECK=1` 을 앞에 붙입니다.

## EC2 요구사항

- Ubuntu 22.04 / 24.04
- **VPC `vpc-prod-edp-hub` 내부**에 위치 (Private 엔드포인트 접근 때문)
- 인터넷 egress 가능 (패키지 설치, GitHub clone) 또는 VPC 엔드포인트 경유
- sudo 권한
- 인스턴스 프로파일 `role-l2comm-mgmt-ec2` 부착 권장 (§4-5 에서 생성)

---

## 1. EC2 기본 패키지 설치

```bash
sudo apt-get update
sudo apt-get install -y git curl unzip ca-certificates gnupg rsync nfs-common
```

### 확인

```bash
git --version
```

기대: `git version 2.x.x`

---

## 2. AWS CLI v2 설치

이미 설치되어 있으면 건너뜁니다.

```bash
aws --version
```

`command not found` 또는 v1 이면 아래를 실행합니다.

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
```

### 확인

```bash
aws --version
```

기대: `aws-cli/2.x.x ...` 출력.

---

## 3. kubectl 설치

GCP 와 달리 별도 인증 플러그인이 필요 없습니다.
`aws eks update-kubeconfig` 가 토큰을 직접 발급합니다.

```bash
curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl
```

### 확인

```bash
kubectl version --client
```

기대: 클라이언트 버전 출력.

---

## 4. Owner 프로파일로 권한 부여  (**Owner 프로파일**)

### 4-1. Owner 프로파일 설정

IAM 사용자 액세스 키를 쓰는 경우:

```bash
aws configure --profile l2comm-owner
```

AWS IAM Identity Center(SSO)를 쓰는 경우:

```bash
aws configure sso --profile l2comm-owner
aws sso login --profile l2comm-owner
```

### 4-2. 배포 주체 프로파일도 미리 설정

```bash
aws configure --profile l2comm-admin
```

### 확인

```bash
aws sts get-caller-identity --profile l2comm-owner
aws sts get-caller-identity --profile l2comm-admin
```

기대: 두 프로파일 모두 Account / Arn 출력.

### 4-3. 저장소 clone

```bash
cd ~
git clone https://github.com/sonmap/AWS_L2Comm-.git
cd ~/AWS_L2Comm-
chmod +x aws/*.sh ssw/dlk/*.sh ssw/dlk/client_eks
chmod +x mnt/batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh
```

### 확인

```bash
ls -l aws/
```

기대: `00-env.sh`, `00-bootstrap.sh`, `05-check-permissions.sh`, `10-network.sh`,
`11-securitygroup.sh`, `20-source-connection.sh`, `30-platform.sh`,
`90-teardown.sh`, `99-verify.sh` 가 실행 권한(`-rwxr-xr-x`)으로 존재.

### 4-4. 변수 확인 (가장 중요)

```bash
vi aws/00-env.sh
```

계정 ID, CIDR, 프로파일명, VPC 이름이 실제 환경과 맞는지 확인하고 수정합니다.
**기본값은 자리표시자(`111122223333` 등)이므로 반드시 바꿔야 합니다.**

```bash
export AWS_PROFILE=l2comm-owner
source aws/00-env.sh

echo "WORKLOAD : ${WORKLOAD_ACCOUNT}"
echo "NETWORK  : ${NETWORK_ACCOUNT}"
echo "DATA     : ${DATA_ACCOUNT}"
echo "REGION   : ${REGION}"
echo "ECR      : ${ECR_REGISTRY}"
echo "OWNER    : ${OWNER_PROFILE}"
echo "ADMIN    : ${ADMIN_PRINCIPAL_ARN}"
echo "APP_ROLE : ${ROLE_APP_ARN}"
echo "IMAGE    : ${IMAGE_URI}"
echo "VM_ROLE  : ${VM_ROLE_ARN}"
echo "BUCKET   : ${DATA_BUCKET}"
```

기대: 모든 값이 출력되고 오류가 없음. 자리표시자 계정 ID 가 남아 있지 않을 것.

> 세 계정 ID 를 모두 같은 값으로 두면 단일 계정 구성으로 동작합니다.
> RAM 공유와 ECR 크로스 계정 정책 단계가 자동으로 생략됩니다.

VPC 가 조회되는지도 확인합니다.

```bash
resolve_vpc_id && echo "VPC_ID=${VPC_ID}"
```

기대: `vpc-` 로 시작하는 ID 출력. 실패하면 `VPC_NAME` 을 고치거나
`VPC_ID` 를 직접 지정하십시오.

이 EC2 자신의 IAM 주체도 확인합니다.

```bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/info
echo
```

기대: `InstanceProfileArn` 이 출력됨. 없으면 §4-5 이후 인스턴스 프로파일을
부착하십시오.

### 4-5. 00-bootstrap 실행

```bash
aws sts get-caller-identity --profile l2comm-owner --query Arn --output text
```

기대: Owner 주체 ARN.

```bash
./aws/00-bootstrap.sh
```

관리 EC2 역할로도 aws CLI 를 돌릴 예정이면:

```bash
GRANT_VM_DEPLOYER=true ./aws/00-bootstrap.sh
```

### 확인

```bash
aws iam get-role --role-name role-l2comm-mgmt-ec2 \
  --profile l2comm-owner --query 'Role.Arn' --output text
```

기대: `arn:aws:iam::<WORKLOAD>:role/role-l2comm-mgmt-ec2`

```bash
aws iam get-user-policy --user-name l2comm-deployer \
  --policy-name L2CommDeployerPolicy --profile l2comm-owner \
  --query 'PolicyDocument.Statement[].Sid' --output text
```

기대 (9개): `EksAdmin`, `CodeBuildEditor`, `EcrAdmin`, `EfsAdmin`,
`IamServiceAccountAdmin`, `NetworkReadOnly`, `LogsViewer`,
`AnalyticsAdmin`, `DataBucket`

> 네트워크 관리(`ec2:CreateSubnet` / `ec2:AuthorizeSecurityGroupIngress`)는
> Owner 영역이므로 배포 주체에게 부여하지 않습니다. 배포 주체는
> `NetworkReadOnly`(`ec2:Describe*`)로 서브넷/보안그룹을 참조만 합니다.

배포 주체가 IAM 역할이면 `get-user-policy` 대신:

```bash
aws iam get-role-policy --role-name l2comm-deployer \
  --policy-name L2CommDeployerPolicy --profile l2comm-owner \
  --query 'PolicyDocument.Statement[].Sid' --output text
```

### 4-6. 조직 수준 권한 확인 (RAM 공유용)

세 계정이 모두 같다면 이 단계는 불필요합니다.

AWS Organizations 안에서 서브넷을 공유하려면 조직 수준에서
RAM 공유가 켜져 있어야 합니다.

```bash
aws ram get-resource-share-associations \
  --association-type PRINCIPAL --profile l2comm-owner --region ap-northeast-2 \
  --query 'resourceShareAssociations[].{share:resourceShareName,principal:associatedEntity,status:status}' \
  --output table 2>/dev/null || echo "RAM 공유 없음"
```

조직 관리 계정에서 한 번 실행해야 하는 설정:

```bash
aws ram enable-sharing-with-aws-organization
```

> 이 명령은 조직 관리 계정에서만 성공합니다. 실패하면 조직 관리자에게
> 요청해야 §5-4 의 RAM 공유가 수신 계정에 자동 수락됩니다.
> 조직 밖 계정 간 공유라면 수신 계정이 초대를 직접 수락해야 합니다.

---

## 5. 네트워크 구성  (**Owner 프로파일 계속**)

VPC 보조 CIDR 추가, 서브넷 생성, RAM 공유, VPC 엔드포인트, 보안그룹은
모두 네트워크 관리 영역이므로 Owner 프로파일로 수행합니다.

### 5-1. 프로파일 확인

```bash
echo "${AWS_PROFILE}"
```

기대: `l2comm-owner` (§4 에서 이미 전환된 상태)

### 5-2. CIDR 중복 사전 확인

```bash
aws ec2 describe-subnets --region ap-northeast-2 \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Cidr:CidrBlock,AZ:AvailabilityZone}' \
  --output table
```

아래 대역과 겹치는 것이 없어야 합니다.

```text
100.64.128.0/19    VPC 보조 CIDR (EKS 노드/Pod)
  100.64.128.0/20    AZ a
  100.64.144.0/20    AZ c
10.252.1.0/24      관리/EFS
  10.252.1.0/25      AZ a
  10.252.1.128/25    AZ c
```

> GCP 의 Control Plane 대역(`10.254.5.0/28`)에 해당하는 예약이 없습니다.
> EKS 는 Control Plane ENI 를 위 EKS 서브넷에 직접 만듭니다.

### 5-3. 보조 CIDR 연결 여부 확인

```bash
aws ec2 describe-vpcs --region ap-northeast-2 --vpc-ids "${VPC_ID}" \
  --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock' --output text
```

`100.64.128.0/19` 가 보이면 이미 연결된 상태입니다.

### 5-4. 10-network 실행 (Owner)

```bash
cd ~/AWS_L2Comm-
./aws/10-network.sh
```

> CIDR 목록을 보여준 뒤 Enter 입력을 기다립니다. 확인 후 Enter.
> VPC 엔드포인트 12개 생성에 2~3분 걸립니다.

### 확인

```bash
aws ec2 describe-subnets --region ap-northeast-2 \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:l2comm-role,Values=eks,infra" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone}' \
  --output table
```

기대: 서브넷 4개가 두 AZ 에 나뉘어 존재.

```bash
aws ec2 describe-vpc-endpoints --region ap-northeast-2 \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[].{Service:ServiceName,State:State}' --output table
```

기대: Gateway 1개(`s3`) + Interface 12개가 `available`.

> `eks-auth` 엔드포인트가 빠지면 Pod Identity 가 동작하지 않습니다.
> 목록에서 반드시 확인하십시오.

### 5-5. 11-securitygroup 실행 (Owner)

```bash
./aws/11-securitygroup.sh
```

스크립트가 하는 일:

1. 보안그룹 3종 생성 (cluster / efs / mgmt)
2. `sg-l2comm-efs` 에 2049 ingress 2건 (cluster SG, mgmt SG)
3. 관리 EC2 에 `sg-l2comm-mgmt` 부착 (IMDS 로 자동 인식, 이미 있으면 SKIP)
4. `sg-l2comm-eks-cluster` 에 443 ingress (mgmt SG)
5. `sg-l2comm-eks-cluster` self 규칙 (Control Plane ↔ Node)

다른 EC2 가 관리 호스트이거나 자동 인식이 실패하면 직접 지정해 재실행합니다.

```bash
aws ec2 describe-instances --region ap-northeast-2 \
  --filters "Name=tag:Name,Values=infra-son01" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,State.Name]' \
  --output table

MGMT_INSTANCE_ID=<ID> ./aws/11-securitygroup.sh
```

> SG 부착에 실패해도 스크립트는 중단되지 않고 나머지 규칙 생성까지 진행합니다.
> `SKIP_MGMT_SG=true` 로 부착 단계를 건너뛸 수 있습니다.

### 확인

```bash
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=group-name,Values=sg-l2comm-eks-cluster,sg-l2comm-efs,sg-l2comm-mgmt" \
  --query 'SecurityGroups[].{Name:GroupName,Id:GroupId}' --output table
```

기대: 3개 모두 출력.

---

## 6. 배포 주체 전환 및 권한 사전 점검  (**배포 주체**)

### 6-1. 프로파일 전환

여기서부터 배포 주체 프로파일로 전환합니다.

```bash
export AWS_PROFILE=l2comm-admin
aws sts get-caller-identity --query Arn --output text
```

기대: 배포 주체 ARN.

### 6-2. 권한 사전 점검 (중요)

20 단계 이후에 필요한 권한을 미리 확인합니다. 여기서 걸러내지 않으면
작업 도중 `AccessDenied` 로 멈춥니다.

```bash
cd ~/AWS_L2Comm-
./aws/05-check-permissions.sh
```

기대: 모든 항목 `OK`, 마지막에 `점검 통과` 메시지.

`FAIL` 이 있으면 어떤 Action 이 거부됐는지 표시됩니다. Owner 로 되돌아가
재실행한 뒤 다시 점검합니다.

```bash
export AWS_PROFILE=l2comm-owner
./aws/00-bootstrap.sh
./aws/10-network.sh            # 서브넷 항목이 FAIL 인 경우
./aws/11-securitygroup.sh      # 보안그룹 항목이 FAIL 인 경우
export AWS_PROFILE=l2comm-admin
./aws/05-check-permissions.sh
```

> `iam:SimulatePrincipalPolicy` 권한이 없으면 스크립트가 `NOTE` 를 출력하고
> 실호출 기반 점검(DEGRADED)으로 내려갑니다. 커버리지가 낮아지므로
> 가능하면 시뮬레이션 권한을 부여하는 편이 낫습니다.

---

## 7. CodeConnections 연결  (**배포 주체**)

GCP 는 Connection 아래에 저장소를 하나씩 등록했지만, CodeConnections 는
GitHub 계정/조직당 연결 1개면 되고 저장소 지정은 CodeBuild 프로젝트에서 합니다.

### 7-1. 기존 연결 확인

```bash
aws codeconnections list-connections --region ap-northeast-2 \
  --provider-type-filter GitHub \
  --query 'Connections[].{Name:ConnectionName,Status:ConnectionStatus}' \
  --output table
```

기대: `github-l2comm` 이 `AVAILABLE`. 없으면 7-3 이 만듭니다.

### 7-2. GitHub App 접근 권한 확인 (선행 조건)

AWS Connector for GitHub 가 **Only select repositories** 로 설치되어 있으면,
GitHub 쪽에서 `AWS_L2Comm-` 을 먼저 허용해야 빌드가 성공합니다.

브라우저에서 확인합니다.

```text
https://github.com/settings/installations
  또는 조직 계정이면
https://github.com/organizations/sonmap/settings/installations
```

`AWS Connector for GitHub` → **Configure** → Repository access 에서
`AWS_L2Comm-` 이 포함되어 있는지 확인하고, 없으면 추가합니다.
(`All repositories` 로 설정되어 있으면 이 단계는 불필요합니다.)

> 이 단계를 건너뛰면 §8 의 CodeBuild 가 소스를 읽지 못하고
> 빌드가 `CLIENT_ERROR` 로 실패합니다.

### 7-3. 연결 생성 실행

```bash
./aws/20-source-connection.sh
```

> 스크립트는 멱등입니다. 이미 있으면 `SKIP (이미 존재)` 를 출력합니다.
>
> **상태가 `PENDING` 이면 스크립트가 콘솔 URL 을 출력하고 exit 1 합니다.**
> 브라우저에서 한 번 승인해야 합니다. CLI 로는 완료할 수 없습니다.
>
>   AWS 콘솔 > Developer Tools > Settings > Connections (리전 ap-northeast-2)
>   `github-l2comm` 선택 > [Update pending connection] > GitHub 앱 설치
>
> 승인 후 스크립트를 다시 실행합니다.

### 확인

```bash
aws codeconnections get-connection --region ap-northeast-2 \
  --connection-arn "$(aws codeconnections list-connections --region ap-northeast-2 \
    --provider-type-filter GitHub \
    --query "Connections[?ConnectionName=='github-l2comm'].ConnectionArn | [0]" \
    --output text)" \
  --query 'Connection.ConnectionStatus' --output text
```

기대: `AVAILABLE`

---

## 8. 플랫폼 구성 (ECR / IAM / Athena / CodeBuild / EKS / EFS)  (**배포 주체**)

```bash
./aws/30-platform.sh
```

> EKS Auto Mode 생성에 **10~15분** 걸립니다. 중간에 끊지 마십시오.
> SSH 가 끊길 염려가 있으면 `tmux` 또는 `screen` 안에서 실행하십시오.
>
> ```bash
> sudo apt-get install -y tmux
> tmux new -s l2comm
> ./aws/30-platform.sh
> # 분리: Ctrl+b 누른 뒤 d / 재접속: tmux attach -t l2comm
> ```

### 8-1. ECR (NETWORK 계정)

```bash
aws ecr describe-repositories --region ap-northeast-2 \
  --query 'repositories[?contains(repositoryName, `l2comm`)].{name:repositoryName,uri:repositoryUri}' \
  --output table
```

기대: `ar-l2comm-python/python-athena-batch`, `ar-l2comm-helm`.

ECR 이 NETWORK 계정에 있으면 **저장소 정책**이 핵심입니다.

```bash
aws ecr get-repository-policy --region ap-northeast-2 \
  --repository-name ar-l2comm-python/python-athena-batch \
  --query 'policyText' --output text | python3 -m json.tool
```

기대:

```text
CrossAccountPush : role-l2comm-codebuild
CrossAccountPull : role-l2comm-eks-node, role-l2comm-mgmt-ec2, 배포 주체
```

> 세 계정이 같으면 이 정책이 없습니다(`RepositoryPolicyNotFoundException`).
> 정상입니다. 같은 계정 안에서는 IAM 정책만으로 충분합니다.

### 8-2. 통합 IAM 역할

```bash
aws iam get-role-policy --role-name role-l2comm-eks \
  --policy-name L2CommAppPolicy \
  --query 'PolicyDocument.Statement[].Sid' --output text
```

기대 (5개): `AthenaQuery`, `GlueCatalog`, `DataBucket`,
`DescribeRegions`, `LogWriter`

신뢰 정책도 확인합니다.

```bash
aws iam get-role --role-name role-l2comm-eks \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text
```

기대: `pods.eks.amazonaws.com` (EKS Pod Identity)

> `ecr:*` 가 여기에 **없어야** 정상입니다. 이미지 Pull 권한은 노드 역할
> (`role-l2comm-eks-node`)과 8-1 의 저장소 정책에 있습니다.

### 8-3. kubectl 접근 권한

```bash
aws eks list-access-entries --region ap-northeast-2 \
  --cluster-name eks-l2comm-batch-an2 --output table
```

기대: 배포 주체 ARN 과 `role-l2comm-mgmt-ec2` 포함.

```bash
aws eks list-associated-access-policies --region ap-northeast-2 \
  --cluster-name eks-l2comm-batch-an2 \
  --principal-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --query 'associatedAccessPolicies[].policyArn' --output text
```

기대: `arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy`

> GCP 의 `roles/container.developer` 대응입니다.
> `authenticationMode=API` 이므로 `aws-auth` ConfigMap 을 편집하지 않습니다.

### 8-4. Glue / Athena

```bash
aws glue get-database --region ap-northeast-2 --name dlk_sample \
  --query 'Database.{name:Name,location:LocationUri}' --output yaml

aws athena get-work-group --region ap-northeast-2 --work-group wg-l2comm \
  --query 'WorkGroup.Configuration.ResultConfiguration.OutputLocation' --output text
```

기대: 데이터베이스가 존재하고, 워크그룹 출력 위치가
`s3://l2comm-dlk-sample-<DATA_ACCOUNT>-ap-northeast-2/athena-results/`.

> GCP 의 `bq add-iam-policy-binding --dataset` allowlist 분기에 해당하는
> 문제가 Glue 에는 없습니다. 폴백 경로가 필요 없습니다.

### 8-5. Pod Identity 연결

```bash
aws eks list-pod-identity-associations --region ap-northeast-2 \
  --cluster-name eks-l2comm-batch-an2 \
  --query 'associations[].{ns:namespace,sa:serviceAccount}' --output table
```

기대 2건:

```text
l2comm-batch  ksa-l2comm-batch        -> role-l2comm-eks
kube-system   efs-csi-controller-sa   -> role-l2comm-eks-efs-csi
```

> GCP 의 Workload Identity 와 달리 **ServiceAccount 에 어노테이션이 없습니다.**
> 연결은 Association 리소스 쪽에만 있습니다.

### 8-6. EKS 클러스터

```bash
aws eks describe-cluster --region ap-northeast-2 --name eks-l2comm-batch-an2 \
  --query 'cluster.{status:status,version:version,
                    autoMode:computeConfig.enabled,
                    nodePools:computeConfig.nodePools,
                    publicAccess:resourcesVpcConfig.endpointPublicAccess,
                    privateAccess:resourcesVpcConfig.endpointPrivateAccess,
                    serviceCidr:kubernetesNetworkConfig.serviceIpv4Cidr,
                    authMode:accessConfig.authenticationMode}' \
  --output yaml
```

기대:

```text
status: ACTIVE
autoMode: true
nodePools: [general-purpose]
publicAccess: false
privateAccess: true
serviceCidr: 10.100.0.0/16      <- EKS managed
authMode: API
```

### 8-7. EFS CSI 애드온

```bash
aws eks describe-addon --region ap-northeast-2 \
  --cluster-name eks-l2comm-batch-an2 --addon-name aws-efs-csi-driver \
  --query 'addon.{name:addonName,status:status,version:addonVersion}' --output yaml
```

기대: `status: ACTIVE`

> EKS Auto Mode 는 EBS 는 기본 제공하지만 EFS 는 제공하지 않습니다.
> 이 애드온이 없으면 §11 에서 Pod 이 `FailedMount` 로 멈춥니다.

### 8-8. CodeBuild 프로젝트

```bash
aws codebuild batch-get-projects --region ap-northeast-2 \
  --names cb-l2comm-python-image \
  --query 'projects[0].{source:source.location,buildspec:source.buildspec,
                        role:serviceRole,privileged:environment.privilegedMode}' \
  --output yaml
```

기대:

```text
source: https://github.com/sonmap/AWS_L2Comm-.git
buildspec: codebuild/buildspec.yml
role: ...role-l2comm-codebuild
privileged: true
```

> **저장소 경로를 반드시 확인하십시오.** 다른 저장소를 가리키면
> 스크립트가 중단하며 교체 명령을 안내합니다.
> `privilegedMode: true` 가 아니면 `docker build` 가 실패합니다.

---

## 9. 이미지 빌드

### 9-1. 수동 빌드 실행

```bash
aws codebuild start-build --region ap-northeast-2 \
  --project-name cb-l2comm-python-image \
  --source-version main \
  --query 'build.id' --output text
```

### 9-2. 상태 확인

```bash
aws codebuild list-builds-for-project --region ap-northeast-2 \
  --project-name cb-l2comm-python-image --max-items 5 \
  --query 'ids' --output text \
  | xargs -n5 aws codebuild batch-get-builds --region ap-northeast-2 --ids \
  --query 'builds[].{id:id,status:buildStatus,phase:currentPhase,start:startTime}' \
  --output table
```

기대: 최신 빌드가 `SUCCEEDED`. `IN_PROGRESS` 면 몇 분 대기 후 재확인.

실패 시 로그:

```bash
BUILD_ID=$(aws codebuild list-builds-for-project --region ap-northeast-2 \
  --project-name cb-l2comm-python-image --max-items 1 \
  --query 'ids[0]' --output text)

LOG=$(aws codebuild batch-get-builds --region ap-northeast-2 --ids "$BUILD_ID" \
  --query 'builds[0].logs.{group:groupName,stream:streamName}' --output text)

aws logs get-log-events --region ap-northeast-2 \
  --log-group-name "$(echo "$LOG" | cut -f1)" \
  --log-stream-name "$(echo "$LOG" | cut -f2)" \
  --query 'events[].message' --output text
```

### 9-3. 이미지 생성 확인

```bash
aws ecr describe-images --region ap-northeast-2 \
  --repository-name ar-l2comm-python/python-athena-batch \
  --query 'imageDetails[].{tags:imageTags,pushed:imagePushedAt,size:imageSizeInBytes}' \
  --output table
```

기대: `v1` 태그.

---

## 10. EC2 EFS 및 kubectl 준비

### 10-1. /ssw/dlk 심볼릭 링크

```bash
cd ~/AWS_L2Comm-
bash ssw/dlk/install-vm.sh
```

같은 EC2 에서 다른 PoC 를 했다면 `/ssw/dlk` 가 이미 다른 체크아웃을
가리키고 있어 아래 오류가 납니다.

```text
ERROR: /ssw/dlk already exists and is not the expected symlink.
```

먼저 무엇을 가리키는지 확인합니다.

```bash
ls -ld /ssw/dlk
readlink -f /ssw/dlk
```

다른 체크아웃을 가리키는 **심볼릭 링크**이면 실행 중인 배치가 없는지 확인한 후
이 저장소로 다시 연결합니다. 실제 디렉터리는 이 명령으로 교체하지 않습니다.

```bash
test -L /ssw/dlk && sudo ln -sfn "$HOME/AWS_L2Comm-/ssw/dlk" /ssw/dlk
bash ssw/dlk/install-vm.sh
```

심볼릭 링크가 아니라 **실제 디렉터리**이면 백업 후 재실행합니다.

```bash
sudo mv /ssw/dlk "/ssw/dlk.bak.$(date +%Y%m%d%H%M%S)"
bash ssw/dlk/install-vm.sh
```

### 확인

```bash
ls -l /ssw/dlk
readlink -f /ssw/dlk
```

기대: `~/AWS_L2Comm-/ssw/dlk` 를 가리키는 심볼릭 링크.

### 10-2. EFS 마운트 및 동기화

```bash
sudo -E bash /ssw/dlk/setup-efs.sh
```

> `-E` 로 `AWS_PROFILE` / `AWS_REGION` 을 sudo 에 넘깁니다.
> Ubuntu 에서는 `amazon-efs-utils` 를 소스에서 빌드하므로 첫 실행이
> 2~3분 걸립니다.

### 확인

```bash
findmnt /srv/l2comm-efs
ls /srv/l2comm-efs/batch_eks/l2/rsvp/GP_L2RSVP_001_1/python
```

기대: EFS 마운트 존재, `athena_auth_smoke.py` 가 보임.
SOURCE 는 `fs-xxxxxxxx.efs.ap-northeast-2.amazonaws.com:/` 여야 합니다.

> **GCP 와의 중요한 차이.** GCP 는 체크아웃을 bind mount 했으므로
> `git pull` 즉시 Pod 에 반영됐습니다. EFS 는 복사본이므로
> **`mnt/` 를 수정하거나 `git pull` 한 뒤에는 이 스크립트를 다시 실행해야 합니다.**

### 10-3. 클러스터 자격증명

`client_eks` 는 기본적으로 `$HOME/.kube/config_eks-automode` 를 봅니다.

```bash
aws eks update-kubeconfig --region ap-northeast-2 \
  --name eks-l2comm-batch-an2 \
  --kubeconfig "$HOME/.kube/config_eks-automode"
```

### 확인

```bash
export KUBECONFIG=$HOME/.kube/config_eks-automode
kubectl cluster-info
kubectl get nodes
```

기대: Control Plane 주소 응답. Auto Mode 는 Pod 수요가 없으면 노드가 0개일 수
있습니다. 그래도 `cluster-info` 는 응답해야 합니다. 타임아웃이면 §13 참고.

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-efs-csi-driver
```

기대: `efs-csi-controller-*` 가 `Running`.

### 10-4. Namespace / ServiceAccount

```bash
kubectl get ns l2comm-batch
kubectl -n l2comm-batch get serviceaccount ksa-l2comm-batch -o yaml
```

기대: 둘 다 존재. **어노테이션은 없는 것이 정상입니다.**
Pod Identity 는 ServiceAccount 어노테이션을 쓰지 않습니다 (§8-5 참고).

없으면 생성합니다.

```bash
kubectl create namespace l2comm-batch
kubectl -n l2comm-batch create serviceaccount ksa-l2comm-batch
```

### 10-5. RSVP 인증 파일 확인

Pod 에는 `SA_KEY_PATH=/home/jupyter/.oefj`,
`AWS_SHARED_CREDENTIALS_FILE=/home/jupyter/.oefj`, `AWS_PROFILE=l2comm`,
`ATHENA_WORKGROUP=wg-l2comm`, `TARGET_DATABASE=dlk_sample` 을 전달합니다.
현재 Python 코드는 프로파일을 명시하며 Pod Identity 나 인스턴스 역할로
대체 인증하지 않습니다. 파일이 없거나 유효하지 않으면 실패합니다.

| EFS 파일 | Pod 경로 |
|---|---|
| `/srv/l2comm-efs/batch_eks/l2/rsvp/.oefj` | `/home/jupyter/.oefj` |
| `/srv/l2comm-efs/batch_eks/l2/rsvp/GP_L2RSVP_001_1/python/athena_auth_smoke.py` | `/home/jupyter/GP_L2RSVP_001_1/python/athena_auth_smoke.py` |

> **GCP 원본의 `.oefj` 를 그대로 복사하면 동작하지 않습니다.**
> 형식이 서비스 계정 JSON 에서 AWS 공유 자격증명 INI 로 바뀌었습니다.

EC2 안에서만 작성하고 Git 에 올리지 않습니다. 내용을 출력하지 마십시오.

```bash
sudo tee /srv/l2comm-efs/batch_eks/l2/rsvp/.oefj >/dev/null <<'EOF'
[l2comm]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
EOF
sudo chmod 0644 /srv/l2comm-efs/batch_eks/l2/rsvp/.oefj
test -r /srv/l2comm-efs/batch_eks/l2/rsvp/.oefj && echo '자격증명 파일 존재'
```

파일과 상위 디렉터리는 Pod 실행 UID 에서 읽고 접근할 수 있어야 합니다.
이 IAM 주체는 Athena 쿼리 실행과 Glue 카탈로그 조회 권한이 필요합니다
(`role-l2comm-eks` 의 `L2CommAppPolicy` 와 같은 범위).

> 장기 액세스 키를 쓰지 않으려면 `.oefj` 검사를 빼고 Pod Identity 만
> 사용하도록 Python 코드를 고치십시오. Association 은 §8-5 에서 이미
> 만들어져 있으므로 `boto3.Session()` 만으로 동작합니다.

---

## 11. RSVP 배치 실행

### 11-1. DRY_RUN — 매니페스트 확인

```bash
cd ~/AWS_L2Comm-
source aws/00-env.sh
export KUBECONFIG="$HOME/.kube/config_eks-automode"
DRY_RUN=1 \
DOCKER_IMAGE="${IMAGE_URI}" \
./mnt/batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh \
  20261016 20261016 20261016 180000 \
  0 4 16 \
  /mnt/batch_eks/l2/rsvp/GP_L2RSVP_001_1/python \
  python athena_auth_smoke.py
```

기대 결과:

| 항목 | 값 |
|---|---|
| 생성 파일 | `pv.yaml`, `pvc.yaml`, `pod.yaml` |
| Kubernetes 리소스 | `apiVersion: v1`, `kind: Pod` |
| PV 드라이버 | `efs.csi.aws.com` |
| volumeHandle | `fs-xxxxxxxx:/batch_eks/l2/rsvp` |
| 마운트 | `/home/jupyter` (읽기 전용) |
| PV / PVC | `l2comm-rsvp-pv` / `l2comm-rsvp-pvc` |
| 작업 경로 | `/home/jupyter/GP_L2RSVP_001_1/python` |
| 리소스 | CPU 4, 메모리 16Gi |

래퍼가 EC2 경로를 Pod 경로로 변환합니다. 첫 9개 인자는 필수이며
10번째 이후는 프로그램 인자입니다.
`DRY_RUN` 기본값은 1입니다. 실제 실행에는 반드시 0을 지정합니다.

> `DOCKER_IMAGE` 는 생략할 수 없습니다. ECR 레지스트리 주소가 계정마다
> 다르므로 `run-eks.sh` 에 기본값을 두지 않았습니다 (GCP 원본과의 차이).

### 11-2. 실제 실행

11-1과 같은 명령에서 `DRY_RUN=1` 만 `DRY_RUN=0` 으로 바꿉니다.

기대 흐름은 PV/PVC 적용 → Pod 생성 → Succeeded 대기 → 로그 출력 →
성공 Pod 삭제입니다.
정상 로그에 `L2COMM: SUCCESS` 와 `[SUCCESS]` 가 표시됩니다.
이 검사는 `SELECT` 상수 쿼리로 인증과 Athena 실행 권한을 확인하며,
테이블을 생성하거나 적재하지 않습니다.

> Auto Mode 는 Pod 을 받고 나서 EC2 를 띄우므로 **첫 실행은 노드 기동에
> 1~2분 더 걸립니다.** `Pending` 상태가 잠시 이어지는 것은 정상입니다.

### 11-3. 다른 터미널에서 관찰

```bash
export KUBECONFIG="$HOME/.kube/config_eks-automode"
kubectl -n l2comm-batch get pods -w
```

실행 중이거나 실패하여 남은 Pod 이름을 확인한 뒤 조회합니다.

```bash
kubectl -n l2comm-batch get pods
# 아래 POD_NAME을 실제 이름으로 바꿉니다.
kubectl -n l2comm-batch describe pod POD_NAME
kubectl -n l2comm-batch logs POD_NAME
```

현재 클라이언트는 성공 Pod 을 즉시 삭제하고 실패 Pod 은 남깁니다.
`KEEP_JOB`, Job TTL, `debug-eks.sh`, CloudWatch Logs 자동 폴백은 지원하지 않습니다.

---

## 12. 결과 및 현재 설정 확인

```bash
cd ~/AWS_L2Comm-
source ssw/dlk/client_common
printf 'EFS_PATH=%s\nPOD_MOUNT_PATH=%s\nPV_NAME=%s\nPVC_NAME=%s\n' \
  "$EFS_PATH" "$POD_MOUNT_PATH" "$PV_NAME" "$PVC_NAME"
findmnt /srv/l2comm-efs
readlink -f /ssw/dlk
```

전체 자원 일괄 점검:

```bash
./aws/99-verify.sh
```

`L2COMM: SUCCESS` 는 인증 검사 성공입니다. `app/main.py` 의 적재 검사와는 다릅니다.
`app/main.py` 역시 `.oefj` 를 명시적으로 사용합니다. 이미지에 포함되므로
변경 적용 시 이미지 재빌드가 필요합니다. `ec2:DescribeRegions` 권한과
S3 쓰기, Glue 테이블 생성 권한이 추가로 필요합니다.
리전 수를 고정된 건수로 검증하지 않습니다.

정기 실행은 수동 테스트 성공 후 동일 RSVP 래퍼와 이미지 변수를 사용해
EC2 crontab 에 등록합니다.

---

## 13. 오류 대응

| 증상 | 원인 | 조치 |
|---|---|---|
| 스크립트가 프로파일 오류로 중단 | 프로파일 분리 규칙 | `00-bootstrap`·`10-network`·`11-securitygroup` 은 `l2comm-owner`, `05`·`20`·`30`·`90` 은 `l2comm-admin`. `export AWS_PROFILE=<프로파일>` |
| `Unable to locate credentials` | 프로파일 미설정 또는 SSO 만료 | `aws configure --profile <이름>` 또는 `aws sso login --profile <이름>` |
| `kubectl` 타임아웃 | VPC 외부이거나 보안그룹 누락 | EC2 가 `vpc-prod-edp-hub` 내부인지 확인, §5-5 의 443 ingress 확인 |
| `AccessDenied` (서브넷 생성) | Owner 아닌 프로파일로 10-network 실행 | `export AWS_PROFILE=l2comm-owner` 후 재실행 |
| EKS 생성 시 서브넷 오류 | 서브넷이 1개 AZ 에만 있음 | EKS 는 최소 2개 AZ 필요. §5-4 확인 |
| RAM 공유가 수신 계정에 안 보임 | 조직 공유 미활성 또는 초대 미수락 | §4-6 확인. 조직 밖이면 `aws ram accept-resource-share-invitation` |
| 클러스터 생성 실패 | 클러스터 역할 정책 누락 | Auto Mode 는 관리형 정책 5개 필요. §8-2 와 `30-platform.sh` §2-2 확인 |
| 빌드 `CLIENT_ERROR` / 소스 접근 실패 | CodeConnections 미승인 또는 GitHub App 접근 불가 | §7-2, §7-3 확인 |
| 빌드 `docker: not found` / `Cannot connect to the Docker daemon` | `privilegedMode` 가 false | §8-8 확인. 프로젝트 재생성 또는 `update-project` |
| 빌드 `denied: ...` push 실패 | CodeBuild 역할의 ECR push 누락 | 크로스 계정이면 **저장소 정책** 확인 (§8-1) |
| Pod `ImagePullBackOff` | 크로스 계정 ECR 권한 또는 엔드포인트 누락 | 저장소 정책 reader 확인 (§8-1), `ecr.api`/`ecr.dkr`/`s3` 엔드포인트 확인 (§5-4) |
| Pod 에서 Athena `AccessDenied` | 키 IAM 주체의 권한 부족 | `.oefj` 주체에 Athena/Glue/S3 권한 확인 (§10-5) |
| PVC `Pending` 또는 Pod `FailedMount` | EFS CSI 애드온 또는 2049 차단 | §8-7 애드온 ACTIVE 확인, §5-5 의 `sg-l2comm-efs` 2049 ingress 확인 |
| `FailedMount ... transport endpoint` | `encryptInTransit` 과 마운트 타깃 불일치 | 마운트 타깃이 Pod 과 같은 AZ 에 있는지 확인 (`99-verify.sh` EFS 절) |
| Pod 에서 파일이 안 보임 | EFS 동기화 미실행 | `sudo -E bash /ssw/dlk/setup-efs.sh` 재실행 (§10-2) |
| Pod 생성 403 | Access Entry 누락 | §8-3 확인. 없으면 `30-platform.sh` 재실행 |
| Pod Identity 가 동작하지 않음 | `eks-auth` VPC 엔드포인트 누락 | §5-4 목록에서 `eks-auth` 확인 |
| `.oefj` 를 읽었는데 인증 실패 | GCP JSON 키를 그대로 복사함 | 형식이 AWS 공유 자격증명 INI 로 바뀜. §10-5 참고 |
| Athena `Table not found` | 테이블이 아직 없음 | `athena_auth_smoke.py` 는 테이블 없이 SELECT 만 수행. 적재는 `app/main.py` |
| Pod 이 오래 `Pending` | Auto Mode 노드 기동 중 | 첫 실행은 1~2분 소요. `kubectl -n l2comm-batch get events` 로 확인 |
| `git pull` 이 local changes 로 중단 | `chmod +x` 로 인한 권한 비트 변경 | `git diff` 로 내용 변경 여부 확인. 권한 비트만이면 `git config core.fileMode false` 후 재시도 |
| `/ssw/dlk already exists and is not the expected symlink` | 이전 체크아웃을 가리키는 링크가 남음 | `readlink -f /ssw/dlk` 로 확인하고 §10-1 절차로 새 링크 연결 |
| `ResourceInUseException` 로 중단 | 멱등 처리 밖의 자원 | 메시지의 자원명을 확인하고 기존 것을 그대로 사용 |
| `BucketAlreadyExists` | S3 버킷 이름은 전역 고유 | `00-env.sh` 의 `DATA_BUCKET` 을 다른 이름으로 변경 |

### 디버깅 명령

```bash
export KUBECONFIG=$HOME/.kube/config_eks-automode

# 이벤트
kubectl -n l2comm-batch get events --sort-by=.lastTimestamp | tail -20

# PVC / PV 상태
kubectl -n l2comm-batch get pvc,pv

# EFS CSI 컨트롤러 로그
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-efs-csi-driver \
  -c efs-plugin --tail=50

# EC2 에서 EFS 자체 점검
findmnt /srv/l2comm-efs
aws efs describe-mount-targets --region ap-northeast-2 \
  --file-system-id "$(aws efs describe-file-systems --region ap-northeast-2 \
    --query "FileSystems[?Name=='efs-l2comm-rsvp'].FileSystemId | [0]" --output text)" \
  --query 'MountTargets[].{subnet:SubnetId,ip:IpAddress,state:LifeCycleState}' --output table

# 현재 프로파일 / 주체
aws sts get-caller-identity
aws configure list
```

---

## 14. 정리

```bash
export KUBECONFIG=$HOME/.kube/config_eks-automode
kubectl -n l2comm-batch get pods -l app=l2comm-batch
# 종료 상태와 이름을 확인한 뒤 개별 삭제합니다.
# kubectl -n l2comm-batch delete pod POD_NAME
```

전체 자원 삭제 (각 단계 확인 프롬프트):

```bash
cd ~/AWS_L2Comm-
./aws/90-teardown.sh
```

> IAM 역할, 보안그룹, VPC 엔드포인트, VPC 보조 CIDR 은 자동 삭제되지 않습니다.
> 스크립트가 마지막에 출력하는 수동 정리 명령을 참고하십시오.
> **VPC 엔드포인트는 시간당 과금되므로 PoC 종료 시 반드시 확인하십시오.**
