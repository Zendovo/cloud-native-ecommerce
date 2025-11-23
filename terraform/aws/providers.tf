#############################################
# Providers, ECR Repositories, and MSK Config
#############################################

# NOTE:
# - This file augments the AWS stack by:
#   1) Adding ECR repositories for container images
#   2) Defining an MSK configuration that enables auto-creation of topics
#   3) Wiring Kubernetes and Helm providers to the EKS cluster

###################
# Kubernetes/Helm #
###################


# Use EKS cluster details to configure Kubernetes and Helm providers
data "aws_eks_cluster" "this" {
  name = aws_eks_cluster.main.name
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.main.name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

#####################
# ECR Repositories  #
#####################

# Minimal set of repositories required by build-and-push scripts
locals {
  ecr_services = [
    "api-gateway",
    "customer-service",
    "product-catalog",
    "order-service",
    "activity-service",
  ]
}

resource "aws_ecr_repository" "services" {
  for_each             = toset(local.ecr_services)
  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = var.project_name
    Service = each.value
  }
}

#########################################
# MSK Configuration (Auto-create topics) #
#########################################

# This configuration enables auto-creation of Kafka topics on MSK.
# To apply it to the cluster, add the following block to aws_msk_cluster.main:
#
# configuration_info {
#   arn      = aws_msk_configuration.auto_create_topics.arn
#   revision = aws_msk_configuration.auto_create_topics.latest_revision
# }
#
# NOTE: The kafka_versions must match the MSK cluster version.
resource "aws_msk_configuration" "auto_create_topics" {
  name           = "${var.project_name}-msk-config"
  kafka_versions = ["3.5.1"]
  description    = "Enable auto.create.topics for minimal setup"

  server_properties = <<-EOF
auto.create.topics.enable=true
delete.topic.enable=true
EOF


}
