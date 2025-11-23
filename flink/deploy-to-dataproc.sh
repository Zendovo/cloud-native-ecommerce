#!/bin/bash

set -e

PROJECT_ID=${GCP_PROJECT_ID:-"your-gcp-project"}
REGION=${GCP_REGION:-"us-central1"}
CLUSTER_NAME=${CLUSTER_NAME:-"ecommerce-analytics-cluster"}
BUCKET_NAME=${FLINK_JOBS_BUCKET:-"${PROJECT_ID}-ecommerce-flink-jobs"}
JOB_JAR="analytics-job-1.0.0.jar"

echo "Building Flink job..."
mvn clean package

echo "Uploading JAR to GCS..."
gsutil cp target/${JOB_JAR} gs://${BUCKET_NAME}/

echo "Submitting Flink job to Dataproc..."
gcloud dataproc jobs submit flink \
    --cluster=${CLUSTER_NAME} \
    --region=${REGION} \
    --jar=gs://${BUCKET_NAME}/${JOB_JAR} \
    --class=com.ecommerce.analytics.AnalyticsJob \
    -- \
    --kafka-bootstrap-servers=${KAFKA_BOOTSTRAP_SERVERS} \
    --input-topic=ecom-raw-events \
    --output-topic=ecom-analytics-results

echo "Flink job submitted successfully!"
