#!/usr/bin/env bash
# gcloud/30-platform.sh 의 aws CLI 등가 구현
#
# 만드는 것: ECR / IAM 역할 / S3+Glue+Athena / CodeBuild / EKS Auto Mode /
#            EFS / EFS CSI 애드온 / Pod Identity / Namespace·KSA
#
# 선행: 00-bootstrap.sh, 10-network.sh, 11-securitygroup.sh, 20-source-connection.sh

source "$(dirname "$0")/00-env.sh"

# 자원 생성/운영 단계 -> 배포 주체로 실행 (Owner 아님)
require_profile "${ADMIN_PROFILE}"
resolve_vpc_id

EKS_SUBNET_A="$(subnet_id_by_name "${EKS_SUBNET_A_NAME}")"
EKS_SUBNET_C="$(subnet_id_by_name "${EKS_SUBNET_C_NAME}")"
INFRA_SUBNET_A="$(subnet_id_by_name "${INFRA_SUBNET_A_NAME}")"
INFRA_SUBNET_C="$(subnet_id_by_name "${INFRA_SUBNET_C_NAME}")"
SG_CLUSTER="$(sg_id_by_name "${SG_CLUSTER_NAME}")"
SG_EFS="$(sg_id_by_name "${SG_EFS_NAME}")"

for V in EKS_SUBNET_A EKS_SUBNET_C INFRA_SUBNET_A INFRA_SUBNET_C SG_CLUSTER SG_EFS; do
  if [[ -z "${!V}" || "${!V}" == "None" ]]; then
    echo "ERROR: ${V} 를 찾지 못했습니다. 10-network.sh / 11-securitygroup.sh 를 먼저 실행하십시오." >&2
    exit 1
  fi
done

###############################################################################
# 1) ECR  (google_artifact_registry_repository 대응)
#
#    ECR 은 NETWORK(구 Host) 계정에 둡니다: ${ECR_ACCOUNT}
#    Push 주체(WORKLOAD 의 CodeBuild 역할)와 Pull 주체(WORKLOAD 의 EKS 노드 역할)가
#    모두 다른 계정에 있으므로 IAM 은 저장소 정책으로 부여합니다(3단계).
###############################################################################
for REPO_PAIR in "${ECR_PYTHON}/${IMAGE_NAME}:L2Comm Python batch images" \
                 "${ECR_HELM}:L2Comm offline OCI Helm charts"; do
  REPO="${REPO_PAIR%%:*}"; DESC="${REPO_PAIR#*:}"
  log "ECR 저장소: ${ECR_ACCOUNT}/${REPO}  (${DESC})"
  ok_if_exists aws ecr create-repository --region "${REGION}" \
    --repository-name "${REPO}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 >/dev/null
done

###############################################################################
# 2) IAM 역할  (google_service_account 대응)
#
#    GCP 의 sa-l2comm-runtime / sa-l2comm-workflow / sa-l2comm-cloudbuild
#    3개를 role-l2comm-eks 하나로 통합했습니다.
#    여기에 EKS Auto Mode 가 별도로 요구하는 클러스터/노드 역할 2개를 더합니다.
###############################################################################

# --- 2-1. 애플리케이션 통합 역할 (Pod Identity 로 Pod 에 전달) ---
log "IAM 역할: ${ROLE_APP_NAME}"
ok_if_exists aws iam create-role --role-name "${ROLE_APP_NAME}" \
  --description "L2Comm EKS 통합 역할 (Build / Runtime)" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "pods.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }' >/dev/null

# --- 2-2. EKS 클러스터 역할 (Auto Mode) ---
log "IAM 역할: ${ROLE_CLUSTER_NAME}"
ok_if_exists aws iam create-role --role-name "${ROLE_CLUSTER_NAME}" \
  --description "L2Comm EKS Auto Mode cluster role" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }' >/dev/null

attach_policies "${ROLE_CLUSTER_NAME}" \
  arn:aws:iam::aws:policy/AmazonEKSClusterPolicy \
  arn:aws:iam::aws:policy/AmazonEKSComputePolicy \
  arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy \
  arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy \
  arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy

# --- 2-3. EKS 노드 역할 (Auto Mode) ---
log "IAM 역할: ${ROLE_NODE_NAME}"
ok_if_exists aws iam create-role --role-name "${ROLE_NODE_NAME}" \
  --description "L2Comm EKS Auto Mode node role" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' >/dev/null

attach_policies "${ROLE_NODE_NAME}" \
  arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly

# --- 2-4. CodeBuild 역할 ---
log "IAM 역할: ${ROLE_CODEBUILD_NAME}"
ok_if_exists aws iam create-role --role-name "${ROLE_CODEBUILD_NAME}" \
  --description "L2Comm CodeBuild image build role" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "codebuild.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' >/dev/null

put_inline_policy "${ROLE_CODEBUILD_NAME}" "L2CommCodeBuildPolicy" "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${WORKLOAD_ACCOUNT}:log-group:/aws/codebuild/${CB_PROJECT}*"
    },
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "EcrPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ECR_ACCOUNT}:repository/${ECR_PYTHON}/*"
    },
    {
      "Sid": "CodeConnections",
      "Effect": "Allow",
      "Action": ["codeconnections:UseConnection", "codestar-connections:UseConnection"],
      "Resource": "*"
    }
  ]
}
JSON
)"

###############################################################################
# 3) 애플리케이션 역할 권한  (google_project_iam_member / dataset IAM 대응)
#
#    GCP Role                  -> AWS Action
#    roles/bigquery.jobUser    -> athena:StartQueryExecution 외
#    roles/bigquery.dataEditor -> glue:*Table / s3:PutObject (dlk_sample 한정)
#    roles/compute.viewer      -> ec2:DescribeRegions 외
#    roles/logging.logWriter   -> logs:PutLogEvents
#    roles/storage.objectViewer-> s3:GetObject
###############################################################################
put_inline_policy "${ROLE_APP_NAME}" "L2CommAppPolicy" "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AthenaQuery",
      "Effect": "Allow",
      "Action": [
        "athena:StartQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "athena:StopQueryExecution",
        "athena:GetWorkGroup",
        "athena:GetDataCatalog"
      ],
      "Resource": [
        "arn:aws:athena:${REGION}:${DATA_ACCOUNT}:workgroup/${ATHENA_WORKGROUP}",
        "arn:aws:athena:${REGION}:${DATA_ACCOUNT}:datacatalog/*"
      ]
    },
    {
      "Sid": "GlueCatalog",
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartition",
        "glue:GetPartitions",
        "glue:CreateTable",
        "glue:UpdateTable",
        "glue:BatchCreatePartition"
      ],
      "Resource": [
        "arn:aws:glue:${REGION}:${DATA_ACCOUNT}:catalog",
        "arn:aws:glue:${REGION}:${DATA_ACCOUNT}:database/${TARGET_DATABASE}",
        "arn:aws:glue:${REGION}:${DATA_ACCOUNT}:table/${TARGET_DATABASE}/*"
      ]
    },
    {
      "Sid": "DataBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::${DATA_BUCKET}",
        "arn:aws:s3:::${DATA_BUCKET}/*"
      ]
    },
    {
      "Sid": "DescribeRegions",
      "Effect": "Allow",
      "Action": ["ec2:DescribeRegions", "ec2:DescribeAvailabilityZones"],
      "Resource": "*"
    },
    {
      "Sid": "LogWriter",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
      "Resource": "arn:aws:logs:${REGION}:${WORKLOAD_ACCOUNT}:log-group:/aws/eks/${CLUSTER_NAME}*"
    }
  ]
}
JSON
)"

# ECR 저장소 정책 (google_artifact_registry_repository_iam_member 대응)
#
# ECR 이 NETWORK 계정에 있으므로 WORKLOAD 계정의 IAM 만으로는 닿지 않습니다.
# 반드시 저장소 정책으로 크로스 계정 접근을 열어야 합니다.
#
#   push : role-l2comm-codebuild   (CodeBuild 가 이미지 Push)
#   pull : role-l2comm-eks-node    (Pod 이미지 Pull)
#          role-l2comm-mgmt-ec2    (관리 EC2 에서 조회)
#          배포 주체               (aws ecr describe-images 확인용)
if [[ "${ECR_ACCOUNT}" != "${WORKLOAD_ACCOUNT}" ]]; then
  log "ECR 크로스 계정 정책: ${ECR_ACCOUNT}/${ECR_PYTHON}/${IMAGE_NAME}"
  aws ecr set-repository-policy --region "${REGION}" \
    --repository-name "${ECR_PYTHON}/${IMAGE_NAME}" \
    --policy-text "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CrossAccountPush",
      "Effect": "Allow",
      "Principal": {"AWS": "${ROLE_CODEBUILD_ARN}"},
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ]
    },
    {
      "Sid": "CrossAccountPull",
      "Effect": "Allow",
      "Principal": {"AWS": ["${ROLE_NODE_ARN}", "${VM_ROLE_ARN}", "${ADMIN_PRINCIPAL_ARN}"]},
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages"
      ]
    }
  ]
}
JSON
)" >/dev/null
else
  log "SKIP: ECR 이 WORKLOAD 계정과 동일하므로 저장소 정책 불필요"
fi

###############################################################################
# 4) 분석 저장소  (BigQuery dataset 대응)
#    S3 버킷 + Glue 데이터베이스 + Athena 워크그룹
###############################################################################
log "S3 버킷: ${DATA_BUCKET}"
ok_if_exists aws s3api create-bucket --region "${REGION}" \
  --bucket "${DATA_BUCKET}" \
  --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
aws s3api put-public-access-block --bucket "${DATA_BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  >/dev/null
aws s3api put-bucket-encryption --bucket "${DATA_BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null

log "Glue 데이터베이스: ${TARGET_DATABASE}"
ok_if_exists aws glue create-database --region "${REGION}" \
  --database-input "{\"Name\":\"${TARGET_DATABASE}\",\"Description\":\"L2Comm sample (was BigQuery dlk_sample)\",\"LocationUri\":\"s3://${DATA_BUCKET}/${TARGET_DATABASE}/\"}" \
  >/dev/null

log "Athena 워크그룹: ${ATHENA_WORKGROUP}"
ok_if_exists aws athena create-work-group --region "${REGION}" \
  --name "${ATHENA_WORKGROUP}" \
  --description "L2Comm batch queries" \
  --configuration "ResultConfiguration={OutputLocation=${ATHENA_OUTPUT}},EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true" \
  >/dev/null

###############################################################################
# 5) CodeBuild 프로젝트  (google_cloudbuild_trigger 대응)
###############################################################################
CONN_ARN="${CC_CONNECTION_ARN:-$(aws codeconnections list-connections --region "${REGION}" \
  --provider-type-filter GitHub \
  --query "Connections[?ConnectionName=='${CC_CONNECTION}'].ConnectionArn | [0]" \
  --output text 2>/dev/null)}"

if [[ -z "${CONN_ARN}" || "${CONN_ARN}" == "None" ]]; then
  echo "ERROR: CodeConnections 연결을 찾지 못했습니다: ${CC_CONNECTION}" >&2
  echo "       ./aws/20-source-connection.sh 를 먼저 실행하십시오." >&2
  exit 1
fi

log "CodeBuild 프로젝트: ${CB_PROJECT}"
if aws codebuild batch-get-projects --region "${REGION}" --names "${CB_PROJECT}" \
     --query 'projects[0].name' --output text 2>/dev/null | grep -qx "${CB_PROJECT}"; then

  # 이미 존재하는 프로젝트가 '다른 저장소'를 가리키면 잘못된 소스로 빌드됩니다.
  CUR_SRC="$(aws codebuild batch-get-projects --region "${REGION}" --names "${CB_PROJECT}" \
    --query 'projects[0].source.location' --output text 2>/dev/null)"

  if [[ "${CUR_SRC}" == "${CB_REMOTE_URI}" || "${CUR_SRC}" == "${CB_REMOTE_URI%.git}" ]]; then
    log "SKIP (이미 존재, 저장소 일치): ${CB_PROJECT}"
  else
    echo "ERROR: CodeBuild 프로젝트 '${CB_PROJECT}' 가 다른 저장소를 가리키고 있습니다." >&2
    echo "       기대: ${CB_REMOTE_URI}" >&2
    echo "       실제: ${CUR_SRC:-<없음>}" >&2
    echo "" >&2
    echo "  조치 1) 소스만 교체" >&2
    echo "    aws codebuild update-project --name ${CB_PROJECT} --region ${REGION} \\" >&2
    echo "      --source type=GITHUB,location=${CB_REMOTE_URI},buildspec=codebuild/buildspec.yml" >&2
    echo "" >&2
    echo "  조치 2) 00-env.sh 의 CB_PROJECT 를 다른 이름으로 바꾸고 재실행" >&2
    echo "    (기존 프로젝트를 계속 써야 하는 경우. 두 프로젝트는 공존 가능)" >&2
    exit 1
  fi
else
  aws codebuild create-project --region "${REGION}" \
    --name "${CB_PROJECT}" \
    --description "Auto-build L2Comm Python image on source updates" \
    --service-role "${ROLE_CODEBUILD_ARN}" \
    --source "{\"type\":\"GITHUB\",\"location\":\"${CB_REMOTE_URI}\",\"buildspec\":\"codebuild/buildspec.yml\",\"auth\":{\"type\":\"CODECONNECTIONS\",\"resource\":\"${CONN_ARN}\"}}" \
    --artifacts '{"type":"NO_ARTIFACTS"}' \
    --environment "{\"type\":\"LINUX_CONTAINER\",\"image\":\"aws/codebuild/amazonlinux2-x86_64-standard:5.0\",\"computeType\":\"BUILD_GENERAL1_SMALL\",\"privilegedMode\":true,\"environmentVariables\":[{\"name\":\"IMAGE_URI\",\"value\":\"${IMAGE_URI}\"},{\"name\":\"ECR_REGISTRY\",\"value\":\"${ECR_REGISTRY}\"},{\"name\":\"AWS_DEFAULT_REGION\",\"value\":\"${REGION}\"}]}" \
    >/dev/null

  # GCP 의 --branch-pattern '^main$' + --included-files 대응
  log "CodeBuild 웹훅: branch=${CB_BRANCH}, paths=app/**, codebuild/**, aws/**"
  ok_if_exists aws codebuild create-webhook --region "${REGION}" \
    --project-name "${CB_PROJECT}" \
    --filter-groups "[[{\"type\":\"EVENT\",\"pattern\":\"PUSH\"},{\"type\":\"HEAD_REF\",\"pattern\":\"^refs/heads/${CB_BRANCH}$\"},{\"type\":\"FILE_PATH\",\"pattern\":\"^(app|codebuild|aws)/\"}]]" \
    >/dev/null
fi

###############################################################################
# 6) EKS Auto Mode 클러스터  (google_container_cluster / create-auto 대응)
#    - 공유 VPC 의 서브넷을 ID 로 지정
#    - Pod 은 노드 서브넷 IP 를 사용 (GKE 의 Pod Secondary Range 없음)
#    - Service 대역은 EKS 관리
#    - Private 엔드포인트만 사용 (endpointPublicAccess=false)
#
#    Auto Mode 는 노드 그룹을 만들지 않습니다. nodePools=general-purpose 를
#    지정하면 Pod 수요에 따라 EC2 가 자동으로 뜨고 사라집니다. GKE Autopilot 과
#    같은 모델입니다.
#
#    Private 노드이므로 공인 인터넷에서 컨테이너를 받아야 한다면 NAT Gateway 가
#    필요합니다. 이 PoC 는 ECR 만 사용하므로 10-network.sh 가 만든 VPC
#    엔드포인트로 충분합니다.
###############################################################################
log "EKS Auto Mode 클러스터: ${CLUSTER_NAME}"
if aws eks describe-cluster --region "${REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  log "SKIP (이미 존재): ${CLUSTER_NAME}"
else
  aws eks create-cluster --region "${REGION}" \
    --name "${CLUSTER_NAME}" \
    --kubernetes-version "${K8S_VERSION}" \
    --role-arn "${ROLE_CLUSTER_ARN}" \
    --resources-vpc-config "subnetIds=${EKS_SUBNET_A},${EKS_SUBNET_C},securityGroupIds=${SG_CLUSTER},endpointPublicAccess=false,endpointPrivateAccess=true" \
    --access-config "authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true" \
    --compute-config "enabled=true,nodeRoleArn=${ROLE_NODE_ARN},nodePools=general-purpose" \
    --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":true}}' \
    --storage-config '{"blockStorage":{"enabled":true}}' \
    >/dev/null

  log "클러스터 ACTIVE 대기 (10~15분)"
  aws eks wait cluster-active --region "${REGION}" --name "${CLUSTER_NAME}"
fi

ACTUAL_STATUS="$(aws eks describe-cluster --region "${REGION}" --name "${CLUSTER_NAME}" \
  --query 'cluster.status' --output text)"
if [[ "${ACTUAL_STATUS}" != "ACTIVE" ]]; then
  echo "ERROR: 클러스터 상태가 ACTIVE 가 아닙니다: ${ACTUAL_STATUS}" >&2
  exit 1
fi
log "클러스터 상태 확인: ${ACTUAL_STATUS}"

# kubectl 접근 권한 (GCP 의 roles/container.developer 대응)
# authenticationMode=API 이므로 aws-auth ConfigMap 대신 Access Entry 를 씁니다.
grant_cluster_admin() {  # grant_cluster_admin <principal_arn>
  log "EKS Access Entry :: $1"
  ok_if_exists aws eks create-access-entry --region "${REGION}" \
    --cluster-name "${CLUSTER_NAME}" --principal-arn "$1" --type STANDARD >/dev/null
  aws eks associate-access-policy --region "${REGION}" \
    --cluster-name "${CLUSTER_NAME}" --principal-arn "$1" \
    --access-scope type=cluster \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    >/dev/null 2>&1 || true
}

grant_cluster_admin "${ADMIN_PRINCIPAL_ARN}"
grant_cluster_admin "${VM_ROLE_ARN}"

###############################################################################
# 7) EFS  (VM 자체 NFS 서버 대응)
#
#    GCP 는 관리 VM 이 직접 nfs-kernel-server 를 띄워 mnt/ 를 export 했습니다.
#    AWS 에서는 관리형 EFS 를 쓰고, 관리 EC2 는 체크아웃의 mnt/ 를 EFS 로
#    동기화하는 역할만 합니다 (ssw/dlk/setup-efs.sh).
###############################################################################
log "EFS 파일 시스템: ${EFS_NAME}"
if resolve_efs_id; then
  log "SKIP (이미 존재): ${EFS_NAME} = ${EFS_ID}"
else
  EFS_ID="$(aws efs create-file-system --region "${REGION}" \
    --creation-token "${EFS_NAME}" \
    --performance-mode generalPurpose \
    --throughput-mode elastic \
    --encrypted \
    --tags "Key=Name,Value=${EFS_NAME}" \
    --query 'FileSystemId' --output text)"
  export EFS_ID
  log "생성: ${EFS_ID}. available 대기"
  for _ in $(seq 1 60); do
    STATE="$(aws efs describe-file-systems --region "${REGION}" \
      --file-system-id "${EFS_ID}" --query 'FileSystems[0].LifeCycleState' --output text)"
    [[ "${STATE}" == "available" ]] && break
    sleep 5
  done
fi

# 마운트 타깃은 관리/EFS 서브넷(기본 CIDR)에 둡니다.
for SID in "${INFRA_SUBNET_A}" "${INFRA_SUBNET_C}"; do
  log "EFS 마운트 타깃: ${SID}"
  ok_if_exists aws efs create-mount-target --region "${REGION}" \
    --file-system-id "${EFS_ID}" \
    --subnet-id "${SID}" \
    --security-groups "${SG_EFS}" >/dev/null
done

###############################################################################
# 8) EFS CSI 드라이버 애드온
#
#    EKS Auto Mode 는 EBS 는 기본 제공하지만 EFS 는 제공하지 않습니다.
#    NFS 마운트를 쓰려면 이 애드온이 필요합니다.
###############################################################################
log "EFS CSI 애드온"
ok_if_exists aws eks create-addon --region "${REGION}" \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name aws-efs-csi-driver \
  --resolve-conflicts OVERWRITE >/dev/null

# CSI 드라이버 자신의 Pod Identity (EFS API 조회용)
log "IAM 역할: ${ROLE_APP_NAME}-efs-csi"
ok_if_exists aws iam create-role --role-name "${ROLE_APP_NAME}-efs-csi" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "pods.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }' >/dev/null
attach_policies "${ROLE_APP_NAME}-efs-csi" \
  arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy

ok_if_exists aws eks create-pod-identity-association --region "${REGION}" \
  --cluster-name "${CLUSTER_NAME}" \
  --namespace kube-system \
  --service-account efs-csi-controller-sa \
  --role-arn "arn:aws:iam::${WORKLOAD_ACCOUNT}:role/${ROLE_APP_NAME}-efs-csi" >/dev/null

###############################################################################
# 9) Pod Identity 연결  (google_service_account_iam_member / Workload Identity 대응)
#
#    GCP: KSA 에 iam.gke.io/gcp-service-account 어노테이션 + workloadIdentityUser
#    AWS: Pod Identity Association 한 줄. KSA 에 어노테이션이 필요 없습니다.
###############################################################################
log "Pod Identity: ${NAMESPACE}/${KSA_NAME} -> ${ROLE_APP_ARN}"
ok_if_exists aws eks create-pod-identity-association --region "${REGION}" \
  --cluster-name "${CLUSTER_NAME}" \
  --namespace "${NAMESPACE}" \
  --service-account "${KSA_NAME}" \
  --role-arn "${ROLE_APP_ARN}" >/dev/null

###############################################################################
# 10) Namespace / KSA 사전 생성
#
#     ssw/dlk/client_eks 도 없으면 생성하지만, Auto Mode 첫 기동 지연을 줄이기
#     위해 플랫폼 구축 단계에서 미리 만듭니다.
#     Private 엔드포인트 클러스터이므로 VPC 내부에서 실행해야 합니다.
###############################################################################
if [[ "${SETUP_K8S:-auto}" != "false" ]]; then
  log "Namespace / KSA 생성 시도 (VPC 내부에서만 성공)"
  KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config_eks-automode}"
  if aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" \
       --kubeconfig "${KUBECONFIG_PATH}" >/dev/null 2>&1 \
     && KUBECONFIG="${KUBECONFIG_PATH}" kubectl version >/dev/null 2>&1; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
      || kubectl create namespace "${NAMESPACE}"
    kubectl -n "${NAMESPACE}" get serviceaccount "${KSA_NAME}" >/dev/null 2>&1 \
      || kubectl -n "${NAMESPACE}" create serviceaccount "${KSA_NAME}"
    # Pod Identity 는 KSA 어노테이션을 요구하지 않습니다 (GCP 와의 차이).
    log "Namespace / KSA 준비 완료"
  else
    log "SKIP: 클러스터 엔드포인트에 접근할 수 없습니다 (VPC 외부이거나 kubectl 미설치)."
    log "      VPC 내부 EC2 에서 ssw/dlk/client_eks 실행 시 자동 생성됩니다."
  fi
fi

###############################################################################
# 11) terraform output 대체
###############################################################################
cat <<EOF

=== Outputs ===
cluster_name          : ${CLUSTER_NAME}  (EKS Auto Mode)
image_uri             : ${IMAGE_URI}
ecr_registry          : ${ECR_REGISTRY}  (ECR 계정 ${ECR_ACCOUNT})
helm_oci_repository   : ${HELM_OCI_URI}
codebuild_project     : ${CB_PROJECT}
namespace             : ${NAMESPACE}
ksa                   : ${KSA_NAME}
app_role              : ${ROLE_APP_ARN}   (Build / Runtime 통합)
efs_id                : ${EFS_ID}
glue_database         : ${TARGET_DATABASE}
athena_workgroup      : ${ATHENA_WORKGROUP}
athena_output         : ${ATHENA_OUTPUT}

EFS_ID 를 00-env.sh 에 고정해 두면 이후 조회가 빨라집니다.
  export EFS_ID="${EFS_ID}"

=== RSVP 배치 실행 (EventBridge / Step Functions 미사용) ===
VPC 내부 EC2에서 docs/RUNBOOK.md §10~11 절차로 EFS와 인증 파일을 확인한 뒤:
  DRY_RUN=1 DOCKER_IMAGE=${IMAGE_URI} \\
  ./mnt/batch_eks/l2_eks_sh/rsvp/GP_L2RSVP_001_1/run-eks.sh \\
    20261016 20261016 20261016 180000 0 4 16 \\
    /home/jupyter/GP_L2RSVP_001_1/python python athena_auth_smoke.py
실제 제출은 DRY_RUN=0으로 변경합니다.
EOF

log "30-platform 완료"
