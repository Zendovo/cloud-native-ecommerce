variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "ecommerce"
}

variable "kafka_bootstrap_servers" {
  description = "AWS MSK Kafka bootstrap servers"
  type        = string
}
