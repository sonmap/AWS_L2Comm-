#!/usr/bin/env bash
# gcloud/99-verify.sh 의 aws CLI 등가 구현
# terraform plan / output 대체 - 생성 자원 상태 일괄 점검

source "$(dirname "$0")/00-env.sh"
set +e

export AWS_PROFILE="${AWS_PROFILE:-$ADMIN_PROFILE}"
resolve_vpc_id

echo "=== Subnet ==="
aws ec2 describe-subnets --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:l2comm-role,Values=eks,infra" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone}' \
  --output table

echo "=== Security Group ==="
aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=group-name,Values=${SG_CLUSTER_NAME},${SG_EFS_NAME},${SG_MGMT_NAME}" \
  --query 'SecurityGroups[].{Name:GroupName,Id:GroupId}' --output table

echo "=== VPC Endpoint ==="
aws ec2 describe-vpc-endpoints --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State}' \
  --output table

echo "=== EKS Cluster ==="
aws eks describe-cluster --region "${REGION}" --name "${CLUSTER_NAME}" \
  --query 'cluster.{name:name,status:status,version:version,
                    autoMode:computeConfig.enabled,
                    nodePools:computeConfig.nodePools,
                    subnets:resourcesVpcConfig.subnetIds,
                    securityGroups:resourcesVpcConfig.securityGroupIds,
                    publicAccess:resourcesVpcConfig.endpointPublicAccess,
                    privateAccess:resourcesVpcConfig.endpointPrivateAccess,
                    serviceCidr:kubernetesNetworkConfig.serviceIpv4Cidr,
                    authMode:accessConfig.authenticationMode}' \
  --output yaml

echo "=== EKS Addon ==="
aws eks list-addons --region "${REGION}" --cluster-name "${CLUSTER_NAME}" --output table

echo "=== Pod Identity Association ==="
aws eks list-pod-identity-associations --region "${REGION}" \
  --cluster-name "${CLUSTER_NAME}" \
  --query 'associations[].{ns:namespace,sa:serviceAccount,id:associationId}' --output table

echo "=== ECR ==="
aws ecr describe-repositories --region "${REGION}" \
  --query 'repositories[?contains(repositoryName, `l2comm`)].{name:repositoryName,uri:repositoryUri}' \
  --output table

echo "=== ECR Image ==="
aws ecr describe-images --region "${REGION}" \
  --repository-name "${ECR_PYTHON}/${IMAGE_NAME}" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].{tags:imageTags,pushed:imagePushedAt,size:imageSizeInBytes}' \
  --output table

echo "=== CodeBuild Project ==="
aws codebuild batch-get-projects --region "${REGION}" --names "${CB_PROJECT}" \
  --query 'projects[0].{name:name,source:source.location,buildspec:source.buildspec,role:serviceRole}' \
  --output yaml

echo "=== CodeBuild 최근 빌드 ==="
BUILD_IDS="$(aws codebuild list-builds-for-project --region "${REGION}" \
  --project-name "${CB_PROJECT}" --max-items 5 --query 'ids' --output text 2>/dev/null)"
if [[ -n "${BUILD_IDS}" && "${BUILD_IDS}" != "None" ]]; then
  # shellcheck disable=SC2086
  aws codebuild batch-get-builds --region "${REGION}" --ids ${BUILD_IDS} \
    --query 'builds[].{id:id,status:buildStatus,start:startTime,phase:currentPhase}' \
    --output table
else
  echo "빌드 이력 없음"
fi

echo "=== 통합 역할 ==="
aws iam get-role --role-name "${ROLE_APP_NAME}" \
  --query 'Role.{arn:Arn,created:CreateDate,trust:AssumeRolePolicyDocument.Statement[0].Principal}' \
  --output yaml
aws iam list-role-policies --role-name "${ROLE_APP_NAME}" --output table

echo "=== EFS ==="
if resolve_efs_id; then
  aws efs describe-file-systems --region "${REGION}" --file-system-id "${EFS_ID}" \
    --query 'FileSystems[0].{id:FileSystemId,name:Name,state:LifeCycleState,size:SizeInBytes.Value,encrypted:Encrypted}' \
    --output yaml
  aws efs describe-mount-targets --region "${REGION}" --file-system-id "${EFS_ID}" \
    --query 'MountTargets[].{subnet:SubnetId,ip:IpAddress,state:LifeCycleState}' --output table
else
  echo "EFS 를 찾지 못했습니다: ${EFS_NAME}"
fi

echo "=== 최근 배치 Pod (VPC 내부에서만 조회 가능) ==="
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config_eks-automode}"
if aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" \
     --kubeconfig "${KUBECONFIG_PATH}" >/dev/null 2>&1 \
   && KUBECONFIG="${KUBECONFIG_PATH}" kubectl version >/dev/null 2>&1; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl get nodes 2>/dev/null
  kubectl -n "${NAMESPACE}" get pods --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -10
  echo "--- PV / PVC ---"
  kubectl -n "${NAMESPACE}" get pvc,pv 2>/dev/null
else
  echo "SKIP: 클러스터 엔드포인트에 접근할 수 없습니다 (VPC 외부이거나 kubectl 미설치)."
fi

echo "=== Athena 결과 ==="
QID="$(aws athena start-query-execution --region "${REGION}" \
  --work-group "${ATHENA_WORKGROUP}" \
  --query-execution-context "Database=${TARGET_DATABASE}" \
  --query-string "SELECT COUNT(*) AS row_count FROM ${TARGET_DATABASE}.${TARGET_TABLE}" \
  --query 'QueryExecutionId' --output text 2>/dev/null)"

if [[ -n "${QID}" && "${QID}" != "None" ]]; then
  for _ in $(seq 1 30); do
    QSTATE="$(aws athena get-query-execution --region "${REGION}" \
      --query-execution-id "${QID}" --query 'QueryExecution.Status.State' --output text)"
    [[ "${QSTATE}" =~ ^(SUCCEEDED|FAILED|CANCELLED)$ ]] && break
    sleep 2
  done
  if [[ "${QSTATE}" == "SUCCEEDED" ]]; then
    aws athena get-query-results --region "${REGION}" --query-execution-id "${QID}" \
      --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
  else
    echo "쿼리 ${QSTATE}: $(aws athena get-query-execution --region "${REGION}" \
      --query-execution-id "${QID}" \
      --query 'QueryExecution.Status.StateChangeReason' --output text)"
    echo "(테이블이 아직 없으면 정상입니다. app/main.py 를 한 번 실행하면 생성됩니다)"
  fi
else
  echo "Athena 쿼리를 제출하지 못했습니다."
fi
