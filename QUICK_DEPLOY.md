# Quick Deployment Guide - MSK Public Access with IAM

## Summary of Changes

**Infrastructure:**
- ✅ Public subnets already configured with IGW
- ✅ MSK configured for public access with IAM auth
- ✅ TLS-only encryption (port 9098)

**Applications:**
- ✅ activity-service updated for IAM auth
- ✅ Flink job updated for IAM auth

## One-Command Deployment

```bash
./scripts/deploy-msk-public-iam.sh
```

This automated script will:
1. Apply Terraform changes
2. Wait for MSK cluster to become ACTIVE (10-20 min)
3. Update Kubernetes ConfigMap
4. Rebuild and push activity-service
5. Build and upload Flink job

## Manual Deployment Steps

### 1. Apply Terraform (10-20 min)

```bash
cd terraform/aws
terraform apply
```

Wait for MSK cluster state = ACTIVE:
```bash
aws kafka describe-cluster \
  --cluster-arn $(aws kafka list-clusters \
    --query "ClusterInfoList[?ClusterName=='ecommerce-kafka'].ClusterArn" \
    --output text --profile kirana_profile) \
  --profile kirana_profile \
  --query 'ClusterInfo.State' \
  --output text
```

### 2. Get Public Bootstrap Brokers

```bash
cd terraform/aws
KAFKA_BROKERS=$(terraform output -raw msk_bootstrap_brokers_public_iam)
echo $KAFKA_BROKERS
```

Example: `b-1.ecommercekafka.xxx.c24.kafka.us-east-1.amazonaws.com:9098,b-2.ecommercekafka.xxx.c24.kafka.us-east-1.amazonaws.com:9098`

### 3. Update Kubernetes ConfigMap

```bash
kubectl patch configmap ecommerce-config -n ecommerce \
  --type merge \
  -p "{\"data\":{\"kafka_bootstrap_servers\":\"$KAFKA_BROKERS\"}}"
```

### 4. Rebuild Activity Service

```bash
cd microservices/activity-service
docker build --platform linux/amd64 -t activity-service:latest .
docker tag activity-service:latest ${ECR_REGISTRY}/activity-service:latest
docker push ${ECR_REGISTRY}/activity-service:latest
```

Restart pods:
```bash
kubectl rollout restart deployment/activity-service -n ecommerce
```

### 5. Build and Upload Flink Job

```bash
cd flink
mvn clean package

# Upload to GCS
FLINK_BUCKET=$(cd ../terraform/gcp && terraform output -raw flink_jobs_bucket)
gsutil cp target/analytics-job-1.0.0.jar gs://${FLINK_BUCKET}/analytics-job.jar
```

### 6. Submit Flink Job to Dataproc

```bash
# Get GCP values
cd terraform/gcp
DATAPROC_CLUSTER=$(terraform output -raw dataproc_cluster_name)
GCP_PROJECT_ID=$(terraform output -raw project_id)
GCP_REGION=$(terraform output -raw region)

# Get AWS values
cd ../aws
DYNAMODB_TABLE=$(terraform output -raw dynamodb_table_name)
AWS_REGION="us-east-1"

# Submit job
gcloud dataproc jobs submit flink \
  --project=${GCP_PROJECT_ID} \
  --cluster=${DATAPROC_CLUSTER} \
  --region=${GCP_REGION} \
  --jar=gs://${FLINK_BUCKET}/analytics-job.jar \
  --properties="containerized.master.env.KAFKA_BOOTSTRAP_SERVERS=${KAFKA_BROKERS},containerized.master.env.KAFKA_INPUT_TOPIC=ecom-raw-events,containerized.master.env.KAFKA_OUTPUT_TOPIC=ecom-analytics-results,containerized.master.env.DYNAMODB_TABLE=${DYNAMODB_TABLE},containerized.master.env.AWS_REGION=${AWS_REGION},containerized.master.env.AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID},containerized.master.env.AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY},containerized.taskmanager.env.KAFKA_BOOTSTRAP_SERVERS=${KAFKA_BROKERS},containerized.taskmanager.env.KAFKA_INPUT_TOPIC=ecom-raw-events,containerized.taskmanager.env.KAFKA_OUTPUT_TOPIC=ecom-analytics-results,containerized.taskmanager.env.DYNAMODB_TABLE=${DYNAMODB_TABLE},containerized.taskmanager.env.AWS_REGION=${AWS_REGION},containerized.taskmanager.env.AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID},containerized.taskmanager.env.AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
```

## Testing

### Test Activity Service

```bash
API_GATEWAY=$(kubectl get svc api-gateway -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -X POST http://${API_GATEWAY}/activity/event \
  -H "Content-Type: application/json" \
  -d '{"user_id":"user123","product_id":"prod456","event_type":"view"}'
```

Check logs:
```bash
kubectl logs -f deployment/activity-service -n ecommerce
```

Expected: `Kafka producer initialized successfully with IAM auth`

### Verify DynamoDB Writes

```bash
aws dynamodb scan --table-name ecommerce-analytics --limit 10 --profile kirana_profile
```

## Connection Details

**Before:**
- Endpoint: Private VPC only
- Port: 9092 (blocked)
- Auth: None
- Status: ❌ Timeout

**After:**
- Endpoint: Public with EIPs
- Port: **9098** (SASL_SSL)
- Auth: **AWS IAM**
- Protocol: **SASL_SSL**
- Status: ✅ Accessible from GCP

## Key Changes Made

1. **MSK Configuration** (`terraform/aws/main.tf`):
   - `public_access.type = "SERVICE_PROVIDED_EIPS"`
   - `client_authentication.sasl.iam = true`
   - `client_broker = "TLS"` (not plaintext)

2. **Activity Service** (`microservices/activity-service/app.py`):
   - Added `aws-msk-iam-sasl-signer-python`
   - Configured `security_protocol="SASL_SSL"`
   - Configured `sasl_mechanism="OAUTHBEARER"`

3. **Flink Job** (`flink/src/main/java/com/ecommerce/analytics/AnalyticsJob.java`):
   - Added `aws-msk-iam-auth` dependency
   - Configured IAM properties for source and sink

## Troubleshooting

**Error: "TimeoutException"**
- MSK cluster not ACTIVE yet - wait longer
- Check: `terraform output msk_bootstrap_brokers_public_iam`

**Error: "Authentication failed"**
- AWS credentials not set
- Export: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`

**Error: "Connection refused on port 9098"**
- Using wrong port (must use 9098, not 9092)
- Security group issue - verify allows 0.0.0.0/0 on 9098

**Activity service crashes**
- Missing AWS_REGION environment variable
- Check ConfigMap: `kubectl get cm ecommerce-config -n ecommerce -o yaml`

## Required AWS IAM Permissions

```json
{
  "Effect": "Allow",
  "Action": [
    "kafka-cluster:Connect",
    "kafka-cluster:DescribeCluster",
    "kafka-cluster:WriteData",
    "kafka-cluster:ReadData"
  ],
  "Resource": [
    "arn:aws:kafka:us-east-1:*:cluster/ecommerce-kafka/*",
    "arn:aws:kafka:us-east-1:*:topic/ecommerce-kafka/*"
  ]
}
```

## Documentation

- **Full Guide**: `MSK_CROSS_CLOUD_SETUP.md`
- **Changes**: `CHANGES_SUMMARY.md`
- **Deployment Script**: `scripts/deploy-msk-public-iam.sh`
