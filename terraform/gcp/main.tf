terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

resource "google_project_service" "dataproc" {
  service = "dataproc.googleapis.com"
}

resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}

resource "google_project_service" "logging" {
  service = "logging.googleapis.com"
}

resource "google_service_account" "dataproc" {
  account_id   = "${var.project_name}-dataproc-sa"
  display_name = "Dataproc Service Account"
}

resource "google_project_iam_member" "dataproc_worker" {
  project = var.gcp_project_id
  role    = "roles/dataproc.worker"
  member  = "serviceAccount:${google_service_account.dataproc.email}"
}

resource "google_project_iam_member" "logging_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.dataproc.email}"
}

resource "google_compute_network" "dataproc_network" {
  name                    = "${var.project_name}-dataproc-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "dataproc_subnet" {
  name          = "${var.project_name}-dataproc-subnet"
  ip_cidr_range = "10.1.0.0/16"
  region        = var.gcp_region
  network       = google_compute_network.dataproc_network.id
}

resource "google_compute_firewall" "dataproc_internal" {
  name    = "${var.project_name}-dataproc-internal"
  network = google_compute_network.dataproc_network.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.1.0.0/16"]
}

resource "google_storage_bucket" "dataproc_staging" {
  name          = "${var.gcp_project_id}-${var.project_name}-dataproc-staging"
  location      = var.gcp_region
  force_destroy = true

  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "flink_jobs" {
  name          = "${var.gcp_project_id}-${var.project_name}-flink-jobs"
  location      = var.gcp_region
  force_destroy = true

  uniform_bucket_level_access = true
}

resource "google_dataproc_cluster" "analytics" {
  name   = "${var.project_name}-analytics-cluster"
  region = var.gcp_region

  cluster_config {
    staging_bucket = google_storage_bucket.dataproc_staging.name

    master_config {
      num_instances = 1
      machine_type  = "n1-standard-2"
      disk_config {
        boot_disk_size_gb = 50
      }
    }

    worker_config {
      num_instances = 2
      machine_type  = "n1-standard-2"
      disk_config {
        boot_disk_size_gb = 50
      }
    }

    software_config {
      image_version       = "2.1-debian11"
      optional_components = ["FLINK"]

      override_properties = {
        "dataproc:dataproc.allow.zero.workers" = "false"
      }
    }

    gce_cluster_config {
      subnetwork      = google_compute_subnetwork.dataproc_subnet.self_link
      service_account = google_service_account.dataproc.email

      service_account_scopes = [
        "https://www.googleapis.com/auth/cloud-platform"
      ]

      internal_ip_only = false
    }

    initialization_action {
      script      = "gs://goog-dataproc-initialization-actions-${var.gcp_region}/kafka/kafka.sh"
      timeout_sec = 500
    }
  }

  depends_on = [
    google_project_service.dataproc,
    google_storage_bucket.dataproc_staging
  ]
}
