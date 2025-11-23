output "dataproc_cluster_name" {
  description = "Dataproc cluster name"
  value       = google_dataproc_cluster.analytics.name
}

output "dataproc_cluster_region" {
  description = "Dataproc cluster region"
  value       = google_dataproc_cluster.analytics.region
}

output "flink_jobs_bucket" {
  description = "GCS bucket for Flink jobs"
  value       = google_storage_bucket.flink_jobs.name
}

output "dataproc_staging_bucket" {
  description = "GCS bucket for Dataproc staging"
  value       = google_storage_bucket.dataproc_staging.name
}

output "dataproc_service_account" {
  description = "Dataproc service account email"
  value       = google_service_account.dataproc.email
}
