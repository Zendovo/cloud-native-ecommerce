output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.main.endpoint
}

output "rds_database_name" {
  description = "RDS database name"
  value       = aws_db_instance.main.db_name
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.analytics.name
}

output "s3_bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.products.bucket
}

output "msk_bootstrap_brokers" {
  description = "MSK Kafka bootstrap brokers (private)"
  value       = aws_msk_cluster.main.bootstrap_brokers
}

output "msk_bootstrap_brokers_public" {
  description = "MSK Kafka public bootstrap brokers"
  value       = aws_msk_cluster.main.bootstrap_brokers_public_sasl_iam
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.product_import.function_name
}
