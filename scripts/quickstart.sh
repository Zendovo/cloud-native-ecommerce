#!/bin/bash
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
echo -e "${YELLOW}Checking prerequisites...${NC}"

command -v terraform >/dev/null 2>&1 || { echo -e "${RED}Error: terraform not found${NC}"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo -e "${RED}Error: aws CLI not found${NC}"; exit 1; }
command -v gcloud >/dev/null 2>&1 || { echo -e "${RED}Error: gcloud not found${NC}"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}Error: kubectl not found${NC}"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo -e "${RED}Error: docker not found${NC}"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Error: helm not found${NC}"; exit 1; }

echo -e "${GREEN}All prerequisites installed${NC}\n"

AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE="kirana_profile"
GCP_PROJECT_ID="sunlit-alloy-479104-p5"
GCP_REGION=${GCP_REGION:-us-central1}

read -sp "Enter RDS Database Password: " DB_PASSWORD
echo ""
if [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}Error: Database password is required${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Phase 1/1: Deploying AWS infrastructure...${NC}"
cd terraform/aws

cat > terraform.tfvars <<EOF
aws_region = "${AWS_REGION}"
project_name = "ecommerce"
db_password = "${DB_PASSWORD}"
EOF

terraform init
terraform apply -auto-approve

RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
KAFKA_BROKERS=$(terraform output -raw msk_bootstrap_brokers)
DYNAMODB_TABLE=$(terraform output -raw dynamodb_table_name)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
EKS_CLUSTER=$(terraform output -raw eks_cluster_name)

echo -e "${GREEN}✓ AWS Infrastructure deployed${NC}"
cd ../..

echo -e "\n${YELLOW}Phase 1/2: Deploying GCP infrastructure...${NC}"
cd terraform/gcp

cat > terraform.tfvars <<EOF
gcp_project_id = "${GCP_PROJECT_ID}"
gcp_region = "${GCP_REGION}"
project_name = "ecommerce"
aws_access_key_id = "${AWS_ACCESS_KEY}"
aws_secret_access_key = "${AWS_SECRET_KEY}"
kafka_bootstrap_servers = "${KAFKA_BROKERS}"
EOF

terraform init
terraform apply -auto-approve

DATAPROC_CLUSTER=$(terraform output -raw dataproc_cluster_name)
FLINK_BUCKET=$(terraform output -raw flink_jobs_bucket)

echo -e "${GREEN}✓ GCP Infrastructure deployed${NC}"
cd ../..

echo -e "\n${YELLOW}Phase 2/3: Configuring kubectl and waiting for EKS nodes...${NC}"
aws eks update-kubeconfig --name ${EKS_CLUSTER} --region ${AWS_REGION} --profile ${AWS_PROFILE}

ATTEMPTS=0
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do
  ATTEMPTS=$((ATTEMPTS+1))
  if [ $ATTEMPTS -ge 32 ]; then
    echo -e "${RED}EKS nodes did not become Ready in time${NC}"
    break
  fi
  echo "Waiting for nodes... ${ATTEMPTS}/32"
  sleep 15
done
kubectl get nodes || true

echo -e "\n${YELLOW}Phase 2/4: Preparing Kubernetes manifests...${NC}"

sed -i.bak "s|ecommerce-db.xxxxx.us-east-1.rds.amazonaws.com|${RDS_ENDPOINT}|g" k8s/namespace-config.yaml
sed -i.bak "s|b-1.ecommerce-kafka.xxxxx.*amazonaws.com:9098.*|${KAFKA_BROKERS}\"|g" k8s/namespace-config.yaml

DB_PASSWORD_B64=$(echo -n "${DB_PASSWORD}" | base64)
sed -i.bak "s|cGFzc3dvcmQxMjM=|${DB_PASSWORD_B64}|g" k8s/namespace-config.yaml

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

for file in k8s/*.yaml; do
    sed -i.bak "s|<YOUR_ECR_REGISTRY>|${ECR_REGISTRY}|g" ${file}
done

echo -e "${GREEN}✓ Manifests updated${NC}"

echo -e "\n${YELLOW}Phase 2/5: Building and pushing Docker images...${NC}"
chmod +x scripts/build-all.sh
./scripts/build-all.sh

echo -e "\n${YELLOW}Phase 3/6: Installing ArgoCD...${NC}"
cd terraform/aws
terraform apply -auto-approve -target=helm_release.argocd -target=helm_release.argocd_apps
cd ../..

kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || echo -e "${YELLOW}ArgoCD server not ready yet${NC}"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")

echo -e "\n${YELLOW}Phase 3/7: ArgoCD deployment (GitOps)...${NC}"
echo "ArgoCD will sync the repository and deploy applications"
echo "Monitor: kubectl get applications -n argocd"

echo -e "\n${YELLOW}Phase 3/8: Deploying observability stack...${NC}"
cd observability
chmod +x install.sh
export GCP_PROJECT_ID=${GCP_PROJECT_ID}
./install.sh
cd ..

echo -e "\n${YELLOW}Phase 3/9: Deploying Flink job...${NC}"
cd flink

if command -v mvn >/dev/null 2>&1; then
    mvn clean package
    gsutil cp target/analytics-job-*.jar gs://${FLINK_BUCKET}/analytics-job.jar
    echo "Flink job uploaded to GCS"
else
    echo -e "${YELLOW}Maven not found, skipping Flink job${NC}"
fi

cd ..

echo -e "\n${YELLOW}Retrieving access information...${NC}"

API_GATEWAY_URL=$(kubectl get svc api-gateway -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo -e "\n${GREEN}Deployment Complete!${NC}\n"

echo -e "${BLUE}Access Information:${NC}"
echo "  API Gateway: http://${API_GATEWAY_URL}"
echo "  ArgoCD: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  ArgoCD Password: ${ARGOCD_PASSWORD}"
echo "  Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo ""

echo -e "${BLUE}Infrastructure:${NC}"
echo "  EKS Cluster: ${EKS_CLUSTER}"
echo "  RDS Endpoint: ${RDS_ENDPOINT}"
echo "  DynamoDB Table: ${DYNAMODB_TABLE}"
echo "  Dataproc Cluster: ${DATAPROC_CLUSTER}"
echo ""

cat > .deployment-info <<EOF
API_GATEWAY_URL=${API_GATEWAY_URL}
ARGOCD_PASSWORD=${ARGOCD_PASSWORD}
EKS_CLUSTER=${EKS_CLUSTER}
RDS_ENDPOINT=${RDS_ENDPOINT}
KAFKA_BROKERS=${KAFKA_BROKERS}
DYNAMODB_TABLE=${DYNAMODB_TABLE}
DATAPROC_CLUSTER=${DATAPROC_CLUSTER}
AWS_REGION=${AWS_REGION}
GCP_PROJECT_ID=${GCP_PROJECT_ID}
GCP_REGION=${GCP_REGION}
EOF

echo -e "${GREEN}Deployment info saved to .deployment-info${NC}"
