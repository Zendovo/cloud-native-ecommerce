#!/bin/bash

set -e

PROJECT_ID=${GCP_PROJECT_ID:-"your-gcp-project"}
REGION=${GCP_REGION:-"us-central1"}
CLUSTER_NAME=${CLUSTER_NAME:-"ecommerce-analytics-cluster"}
BUCKET_NAME=${FLINK_JOBS_BUCKET:-"${PROJECT_ID}-ecommerce-flink-jobs"}
JOB_JAR="analytics-job-1.0.0.jar"

# Get required environment variables
AWS_ACCESS_KEY=${AWS_ACCESS_KEY_ID:-$(aws configure get aws_access_key_id 2>/dev/null || echo "")}
AWS_SECRET_KEY=${AWS_SECRET_ACCESS_KEY:-$(aws configure get aws_secret_access_key 2>/dev/null || echo "")}
KAFKA_SERVERS=${KAFKA_BOOTSTRAP_SERVERS:-"localhost:9092"}
DYNAMO_TABLE=${DYNAMODB_TABLE:-"ecommerce-analytics"}
AWS_REGION_VAR=${AWS_REGION:-"us-east-1"}

echo "Building Flink job..."
mvn clean package

echo "Uploading JAR to GCS..."
gsutil cp target/${JOB_JAR} gs://${BUCKET_NAME}/

echo "Submitting Flink job to Dataproc..."
echo "Kafka Servers: ${KAFKA_SERVERS}"
echo "DynamoDB Table: ${DYNAMO_TABLE}"
echo "AWS Region: ${AWS_REGION_VAR}"

# Create a properties file for environment variables
cat > /tmp/flink-job.properties <<EOF
containerized.master.env.KAFKA_BOOTSTRAP_SERVERS=${KAFKA_SERVERS}
containerized.master.env.KAFKA_INPUT_TOPIC=ecom-raw-events
containerized.master.env.KAFKA_OUTPUT_TOPIC=ecom-analytics-results
containerized.master.env.DYNAMODB_TABLE=${DYNAMO_TABLE}
containerized.master.env.AWS_REGION=${AWS_REGION_VAR}
containerized.master.env.AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
containerized.master.env.AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}
containerized.taskmanager.env.KAFKA_BOOTSTRAP_SERVERS=${KAFKA_SERVERS}
containerized.taskmanager.env.KAFKA_INPUT_TOPIC=ecom-raw-events
containerized.taskmanager.env.KAFKA_OUTPUT_TOPIC=ecom-analytics-results
containerized.taskmanager.env.DYNAMODB_TABLE=${DYNAMO_TABLE}
containerized.taskmanager.env.AWS_REGION=${AWS_REGION_VAR}
containerized.taskmanager.env.AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
containerized.taskmanager.env.AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}
EOF

# Convert properties to comma-separated format
PROPERTIES=$(cat /tmp/flink-job.properties | tr '\n' ',' | sed 's/,$//')

gcloud dataproc jobs submit flink \
    --cluster=${CLUSTER_NAME} \
    --region=${REGION} \
    --jar=gs://${BUCKET_NAME}/${JOB_JAR} \
    --class=com.ecommerce.analytics.AnalyticsJob \
    --properties="${PROPERTIES}" 2>&1 | tee /tmp/flink-submit.log

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "Flink job submitted successfully!"
else
    echo "ERROR: Flink job submission failed. Check logs above."
    echo ""
    echo "Troubleshooting tips:"
    echo "1. Verify AWS credentials are set: echo \$AWS_ACCESS_KEY_ID"
    echo "2. Check Kafka bootstrap servers: echo \$KAFKA_BOOTSTRAP_SERVERS"
    echo "3. Ensure DynamoDB table exists: aws dynamodb describe-table --table-name ${DYNAMO_TABLE}"
    echo "4. Check Dataproc cluster status: gcloud dataproc clusters describe ${CLUSTER_NAME} --region=${REGION}"
    echo "5. View detailed job logs with: gcloud logging read \"resource.type=cloud_dataproc_job\" --limit=50"
    exit 1
fi

# Clean up
rm -f /tmp/flink-job.properties
