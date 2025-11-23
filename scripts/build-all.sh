#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

SERVICES=(
    "api-gateway"
    "customer-service"
    "product-catalog"
    "order-service"
    "activity-service"
)

echo -e "${YELLOW}=== E-Commerce Platform - Build All Microservices ===${NC}\n"

if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Unable to get AWS Account ID. Please configure AWS CLI.${NC}"
    exit 1
fi

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"
echo "ECR Registry: $ECR_REGISTRY"
echo ""

echo -e "${YELLOW}Creating ECR repositories...${NC}"
for service in "${SERVICES[@]}"; do
    echo "Creating repository for ${service}..."
    aws ecr describe-repositories --repository-names ${service} --region ${AWS_REGION} >/dev/null 2>&1 || \
        aws ecr create-repository --repository-name ${service} --region ${AWS_REGION} >/dev/null
    echo -e "${GREEN}✓${NC} ${service} repository ready"
done
echo ""

echo -e "${YELLOW}Logging into ECR...${NC}"
aws ecr get-login-password --region ${AWS_REGION} | \
    docker login --username AWS --password-stdin ${ECR_REGISTRY}
echo -e "${GREEN}✓${NC} Logged into ECR"
echo ""

for service in "${SERVICES[@]}"; do
    echo -e "${YELLOW}Building ${service}...${NC}"

    cd microservices/${service}

    echo "  Building Docker image..."
    docker build -t ${service}:latest . -q

    echo "  Tagging image..."
    docker tag ${service}:latest ${ECR_REGISTRY}/${service}:latest

    echo "  Pushing to ECR..."
    docker push ${ECR_REGISTRY}/${service}:latest -q

    echo -e "${GREEN}✓${NC} ${service} built and pushed successfully"
    echo ""

    cd ../..
done

echo -e "${GREEN}=== All microservices built and pushed successfully! ===${NC}"
echo ""
echo "Next steps:"
echo "1. Update k8s manifests with ECR registry: ${ECR_REGISTRY}"
echo "2. Deploy using ArgoCD or kubectl apply -f k8s/"
echo "3. Run load tests: cd load-testing && k6 run load-test.js"
