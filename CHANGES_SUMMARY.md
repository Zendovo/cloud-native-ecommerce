# MSK Public Access + IAM Authentication - Changes Summary

## Overview

Enabled AWS MSK public access with IAM authentication to allow GCP Dataproc (Flink) to connect to AWS MSK cluster.

## Infrastructure Changes

### ✅ Terraform (`terraform/aws/main.tf`)

**Already configured:**
- Public subnets with IGW route (lines 35-47, 87-100, 113-117)
- Internet Gateway attached to VPC (lines 68-74)
- Route table with IGW route (lines 87-100)

**Updated MSK cluster configuration:**
```hcl
resource "aws_msk_cluster" "main" {
  broker_node_group_info {
    client_subnets  = aws_subnet.public[*].id  # Uses public subnets
    
    connectivity_info {
      public_access {
        type = "SERVICE_PROVIDED_EIPS"  # ENABLED public access
      }
    }
  }
  
  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"    # TLS only (AWS requirement)
      in_cluster    = true
    }
  }
  
  client_authentication {
    sasl {
      iam = true              # IAM authentication ENABLED
    }
  }
}
```

**Compliance with AWS Public Access Rules:**
- ✅ Rule 1: Public subnets with IGW
- ✅ Rule 2: IAM authentication enabled (not unauthenticated)
- ✅ Rule 3: In-cluster encryption enabled
- ✅ Rule 4: TLS-only client-broker (no plaintext)

### Terraform Outputs (`terraform/aws/outputs.tf`)

Updated outputs to expose IAM-enabled endpoints:
```hcl
output "msk_bootstrap_brokers_tls" {
  description = "MSK Kafka bootstrap brokers (private TLS)"
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
}

output "msk_bootstrap_brokers_public_iam" {
  description = "MSK Kafka public bootstrap brokers (TLS + IAM auth)"
  value       = aws_msk_cluster.main.bootstrap_brokers_public_sasl_iam
}
```

## Application Changes

### 1. Activity Service (Python)

**File: `microservices/activity-service/requirements.txt`**
```diff
+ aws-msk-iam-sasl-signer-python==1.0.1
+ boto3==1.34.0
```

**File: `microservices/activity-service/app.py`**

Added IAM authentication:
```python
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

def oauth_cb():
    """Generate AWS MSK IAM authentication token"""
    token, _ = MSKAuthTokenProvider.generate_auth_token(AWS_REGION)
    return token

def get_kafka_producer():
    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS.split(","),
        security_protocol="SASL_SSL",      # IAM requires SASL_SSL
        sasl_mechanism="OAUTHBEARER",       # OAuth mechanism
        sasl_oauth_token_provider=oauth_cb, # Token generator
        # ... other settings
    )
```

**File: `k8s/activity-service.yaml`**

Updated environment variables:
```yaml
env:
  - name: KAFKA_BOOTSTRAP_SERVERS
    valueFrom:
      configMapKeyRef:
        name: ecommerce-config
        key: kafka_bootstrap_servers
  - name: AWS_REGION              # NEW
    valueFrom:
      configMapKeyRef:
        name: ecommerce-config
        key: aws_region
```

### 2. Flink Job (Java)

**File: `flink/pom.xml`**

Added AWS MSK IAM auth library:
```xml
<dependency>
    <groupId>software.amazon.msk</groupId>
    <artifactId>aws-msk-iam-auth</artifactId>
    <version>1.1.6</version>
</dependency>
```

**File: `flink/src/main/java/com/ecommerce/analytics/AnalyticsJob.java`**

Added IAM authentication properties for both source and sink:
```java
// Kafka Source Configuration
Properties kafkaProps = new Properties();
kafkaProps.setProperty("security.protocol", "SASL_SSL");
kafkaProps.setProperty("sasl.mechanism", "AWS_MSK_IAM");
kafkaProps.setProperty("sasl.jaas.config", 
    "software.amazon.msk.auth.iam.IAMLoginModule required;");
kafkaProps.setProperty("sasl.client.callback.handler.class",
    "software.amazon.msk.auth.iam.IAMClientCallbackHandler");

KafkaSource<String> source = KafkaSource.<String>builder()
    .setBootstrapServers(kafkaBootstrapServers)
    .setProperties(kafkaProps)  // Apply IAM auth
    .build();

// Kafka Sink Configuration (same properties)
KafkaSink<String> sink = KafkaSink.<String>builder()
    .setBootstrapServers(kafkaBootstrapServers)
    .setKafkaProducerConfig(sinkKafkaProps)  // Apply IAM auth
    .build();
```

## Deployment Scripts

### Created: `scripts/deploy-msk-public-iam.sh`

Automated deployment script that:
1. Applies Terraform changes
2. Waits for MSK cluster to become ACTIVE (10-20 min)
3. Retrieves public IAM bootstrap brokers
4. Updates Kubernetes ConfigMap
5. Rebuilds and pushes activity-service Docker image
6. Builds Flink job JAR
7. Uploads Flink job to GCS

Usage:
```bash
./scripts/deploy-msk-public-iam.sh
```

## Connection Details

### Before Changes
- **Endpoint**: Private VPC only
- **Port**: 9092 (plaintext) - not accessible
- **Authentication**: None
- **Status**: Connection timeouts from GCP

### After Changes
- **Endpoint**: Public with EIPs (from `msk_bootstrap_brokers_public_iam`)
- **Port**: 9098 (SASL_SSL)
- **Authentication**: AWS IAM
- **Protocol**: SASL_SSL
- **SASL Mechanism**: AWS_MSK_IAM
- **Status**: Accessible from GCP Dataproc with AWS credentials

## Required AWS Credentials

For Flink job running on GCP to access MSK + DynamoDB:

```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
```

**Required IAM Permissions:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kafka-cluster:Connect",
        "kafka-cluster:AlterCluster",
        "kafka-cluster:DescribeCluster"
      ],
      "Resource": "arn:aws:kafka:us-east-1:*:cluster/ecommerce-kafka/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kafka-cluster:*Topic*",
        "kafka-cluster:WriteData",
        "kafka-cluster:ReadData"
      ],
      "Resource": "arn:aws:kafka:us-east-1:*:topic/ecommerce-kafka/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kafka-cluster:AlterGroup",
        "kafka-cluster:DescribeGroup"
      ],
      "Resource": "arn:aws:kafka:us-east-1:*:group/ecommerce-kafka/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:*:table/ecommerce-analytics"
    }
  ]
}
```

## Testing

### 1. Verify MSK Cluster Status
```bash
cd terraform/aws
terraform output msk_bootstrap_brokers_public_iam
```

### 2. Test Activity Service
```bash
API_GATEWAY=$(kubectl get svc api-gateway -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -X POST http://${API_GATEWAY}/activity/event \
  -H "Content-Type: application/json" \
  -d '{"user_id":"test123","product_id":"prod456","event_type":"view"}'
```

Check logs:
```bash
kubectl logs -f deployment/activity-service -n ecommerce
```

Look for: `Kafka producer initialized successfully with IAM auth`

### 3. Submit Flink Job
See `scripts/deploy-msk-public-iam.sh` output for detailed submission command.

### 4. Verify DynamoDB Writes
```bash
aws dynamodb scan --table-name ecommerce-analytics --limit 10 --profile kirana_profile
```

## Files Modified

1. `terraform/aws/main.tf` - MSK public access + IAM auth
2. `terraform/aws/outputs.tf` - Public IAM broker outputs
3. `microservices/activity-service/requirements.txt` - Added IAM libs
4. `microservices/activity-service/app.py` - IAM authentication
5. `k8s/activity-service.yaml` - AWS_REGION env var
6. `flink/pom.xml` - AWS MSK IAM auth dependency
7. `flink/src/main/java/com/ecommerce/analytics/AnalyticsJob.java` - IAM config

## Files Created

1. `scripts/deploy-msk-public-iam.sh` - Deployment automation
2. `MSK_CROSS_CLOUD_SETUP.md` - Detailed documentation
3. `CHANGES_SUMMARY.md` - This file

## Security Considerations

- ✅ TLS encryption in transit
- ✅ IAM-based authentication (not anonymous)
- ✅ Minimal IAM permissions required
- ⚠️ Public endpoints (required for cross-cloud access)
- ⚠️ AWS credentials in GCP (use GCP Secret Manager in production)
- ⚠️ Cross-cloud data egress costs apply

## Architecture Compliance

This setup maintains the assignment requirement:
> "One analytical service must run on a different cloud provider (B)"

- ✅ Flink runs on GCP Dataproc (Provider B)
- ✅ MSK runs on AWS (Provider A)
- ✅ Cross-cloud connectivity via public IAM-authenticated endpoints
- ✅ Terraform-managed infrastructure
- ✅ Follows AWS security best practices for public MSK access
