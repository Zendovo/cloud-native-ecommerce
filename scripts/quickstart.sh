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

echo -e "${GREEN} All prerequisites installed${NC}\n"

read -p "Enter AWS Region [us-east-1]: " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}

read -p "Enter GCP Project ID: " GCP_PROJECT_ID
if [ -z "$GCP_PROJECT_ID" ]; then
    echo -e "${RED}Error: GCP Project ID is required${NC}"
    exit 1
fi

read -p "Enter GCP Region [us-central1]: " GCP_REGION
GCP_REGION=${GCP_REGION:-us-central1}

read -sp "Enter RDS Database Password: " DB_PASSWORD
echo ""
if [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}Error: Database password is required${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Step 1/10: Deploying AWS Infrastructure...${NC}"
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

echo -e "\n${YELLOW}Step 2/10: Deploying GCP Infrastructure...${NC}"
cd terraform/gcp

AWS_ACCESS_KEY=$(aws configure get aws_access_key_id)
AWS_SECRET_KEY=$(aws configure get aws_secret_access_key)

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

echo -e "\n${YELLOW}Step 3/10: Configuring kubectl...${NC}"
aws eks update-kubeconfig --name ${EKS_CLUSTER} --region ${AWS_REGION}
echo -e "${GREEN}✓ kubectl configured${NC}"

echo -e "\n${YELLOW}Step 4/10: Updating Kubernetes manifests...${NC}"

sed -i.bak "s|ecommerce-db.xxxxx.us-east-1.rds.amazonaws.com|${RDS_ENDPOINT}|g" k8s/namespace-config.yaml
sed -i.bak "s|b-1.ecommerce-kafka.xxxxx.*amazonaws.com:9092.*|${KAFKA_BROKERS}\"|g" k8s/namespace-config.yaml

DB_PASSWORD_B64=$(echo -n "${DB_PASSWORD}" | base64)
sed -i.bak "s|cGFzc3dvcmQxMjM=|${DB_PASSWORD_B64}|g" k8s/namespace-config.yaml

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

for file in k8s/*.yaml; do
    sed -i.bak "s|<YOUR_ECR_REGISTRY>|${ECR_REGISTRY}|g" ${file}
done

echo -e "${GREEN}✓ Kubernetes manifests updated${NC}"

echo -e "\n${YELLOW}Step 5/10: Building and pushing Docker images...${NC}"
chmod +x scripts/build-all.sh
./scripts/build-all.sh

echo -e "${GREEN}✓ Docker images built and pushed${NC}"

echo -e "\n${YELLOW}Step 6/10: GitOps (ArgoCD) Setup Skipped${NC}"
echo "ArgoCD is provisioned via Terraform (helm_release). No manual installation executed."
echo "To retrieve initial admin password (optional):"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

echo -e "\n${YELLOW}Step 7/10: Deploying applications (GitOps)${NC}"
echo "Skipping direct manual deployment. ArgoCD will sync the repository and create/update all Kubernetes objects."
echo "You can monitor sync status:"
echo "  kubectl get applications -n argocd"
echo "  kubectl get pods -n ecommerce"

echo -e "\n${YELLOW}Step 8/10: Deploying observability stack...${NC}"
cd observability
chmod +x install.sh
export GCP_PROJECT_ID=${GCP_PROJECT_ID}
./install.sh
cd ..

echo -e "${GREEN}✓ Observability stack deployed${NC}"

echo -e "\n${YELLOW}Step 9/10: Deploying Flink analytics job...${NC}"
cd flink

if command -v mvn >/dev/null 2>&1; then
    echo "Building Flink job..."
    mvn clean package

    echo "Uploading to GCS..."
    gsutil cp target/analytics-job-*.jar gs://${FLINK_BUCKET}/analytics-job.jar

    echo "Submitting to Dataproc with environment variables..."
    echo "  Kafka Brokers: ${KAFKA_BROKERS}"
    echo "  DynamoDB Table: ${DYNAMODB_TABLE}"
    echo "  AWS Region: ${AWS_REGION}"

    gcloud dataproc jobs submit flink \
        --cluster=${DATAPROC_CLUSTER} \
        --region=${GCP_REGION} \
        --jar=gs://${FLINK_BUCKET}/analytics-job.jar \
        --class=com.ecommerce.analytics.AnalyticsJob \
        --properties="containerized.master.env.KAFKA_BOOTSTRAP_SERVERS=${KAFKA_BROKERS},containerized.master.env.KAFKA_INPUT_TOPIC=ecom-raw-events,containerized.master.env.KAFKA_OUTPUT_TOPIC=ecom-analytics-results,containerized.master.env.DYNAMODB_TABLE=${DYNAMODB_TABLE},containerized.master.env.AWS_REGION=${AWS_REGION},containerized.master.env.AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY},containerized.master.env.AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY},containerized.taskmanager.env.KAFKA_BOOTSTRAP_SERVERS=${KAFKA_BROKERS},containerized.taskmanager.env.KAFKA_INPUT_TOPIC=ecom-raw-events,containerized.taskmanager.env.KAFKA_OUTPUT_TOPIC=ecom-analytics-results,containerized.taskmanager.env.DYNAMODB_TABLE=${DYNAMODB_TABLE},containerized.taskmanager.env.AWS_REGION=${AWS_REGION},containerized.taskmanager.env.AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY},containerized.taskmanager.env.AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}" \
        && echo -e "${GREEN}✓ Flink job submitted successfully${NC}" \
        || echo -e "${YELLOW}⚠ Flink job submission failed (optional)${NC}"
else
    echo -e "${YELLOW}Maven not found, skipping Flink job build${NC}"
fi

cd ..
echo -e "${GREEN}✓ Flink job deployment attempted${NC}"

echo -e "\n${YELLOW}Step 10/10: Retrieving access information...${NC}"

echo "Waiting for LoadBalancer to be assigned..."
sleep 30

API_GATEWAY_URL=$(kubectl get svc api-gateway -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           Deployment Complete!                             ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"

echo -e "${BLUE}Access Information:${NC}"
echo -e "  API Gateway URL: http://${API_GATEWAY_URL}"
echo -e "  ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo -e "  ArgoCD Password: ${ARGOCD_PASSWORD}"
echo -e "  Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo -e "  Grafana User: admin / admin123"
echo ""

echo -e "${BLUE}Infrastructure Details:${NC}"
echo -e "  EKS Cluster: ${EKS_CLUSTER}"
echo -e "  RDS Endpoint: ${RDS_ENDPOINT}"
echo -e "  DynamoDB Table: ${DYNAMODB_TABLE}"
echo -e "  Dataproc Cluster: ${DATAPROC_CLUSTER}"
echo ""

echo -e "${BLUE}Next Steps:${NC}"
echo -e "  1. Test API: curl http://${API_GATEWAY_URL}/products"
echo -e "  2. Run load tests: cd load-testing && API_GATEWAY_URL=http://${API_GATEWAY_URL} k6 run load-test.js"
echo -e "  3. Monitor HPA: watch kubectl get hpa -n ecommerce"
echo -e "  4. View logs: kubectl logs -f -l app=api-gateway -n ecommerce"
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

echo -e "${GREEN}Deployment information saved to .deployment-info${NC}\n"
