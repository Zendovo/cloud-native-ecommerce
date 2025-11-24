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
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--profile", "kirana_profile"]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--profile", "kirana_profile"]
    }
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

# ECR Repository Policy to allow public pull access
resource "aws_ecr_repository_policy" "services_public_access" {
  for_each   = toset(local.ecr_services)
  repository = aws_ecr_repository.services[each.key].name

  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [
      {
        Sid       = "AllowPublicPull"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
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
