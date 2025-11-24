#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile kirana_profile 2>/dev/null || echo "")
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

SERVICES=(
    # "api-gateway"
    # "customer-service"
    # "product-catalog"
    # "order-service"
    "activity-service"
)

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
    aws ecr describe-repositories --repository-names ${service} --region ${AWS_REGION} --profile kirana_profile >/dev/null 2>&1 || \
        aws ecr create-repository --repository-name ${service} --region ${AWS_REGION} --profile kirana_profile >/dev/null
    echo -e "${GREEN}✓${NC} ${service}"
done
echo ""

echo -e "${YELLOW}Logging into ECR...${NC}"
aws ecr get-login-password --region ${AWS_REGION} --profile kirana_profile | \
    docker login --username AWS --password-stdin ${ECR_REGISTRY}
echo ""

for service in "${SERVICES[@]}"; do
    echo -e "${YELLOW}Building ${service}...${NC}"
    cd microservices/${service}

    echo "  Building Docker image for linux/amd64..."
    docker build --platform linux/amd64 -t ${service}:latest . -q

    echo "  Tagging image..."
    docker tag ${service}:latest ${ECR_REGISTRY}/${service}:latest
    docker push ${ECR_REGISTRY}/${service}:latest -q
    
    echo -e "${GREEN}✓${NC} ${service}"
    cd ../..
done

echo -e "${GREEN}All microservices built and pushed${NC}"
