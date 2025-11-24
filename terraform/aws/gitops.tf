#############################################
# GitOps with ArgoCD installed via Helm
# - Installs ArgoCD into EKS cluster
# - Provisions ArgoCD Applications using argocd-apps Helm chart
#############################################

#############################################
# Variables
#############################################
variable "git_repo_url" {
  description = "Git repository URL tracked by ArgoCD"
  type        = string
  default     = "https://github.com/zendovo/cloud-native-ecommerce.git"
}

variable "git_repo_revision" {
  description = "Git revision (branch, tag, or commit) to track"
  type        = string
  default     = "main"
}

#############################################
# Namespace for ArgoCD
#############################################
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/name"       = "argocd"
      "app.kubernetes.io/part-of"    = "gitops"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

#############################################
# Install ArgoCD via Helm
#############################################
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"

  # Optionally pin a version (uncomment and set a known good version)
  # version = "5.51.6"

  # Ensure CRDs installed
  set {
    name  = "crds.install"
    value = "true"
  }

  # Expose ArgoCD server publicly (LoadBalancer) to satisfy public URL requirement
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  # Keep it minimal
  set {
    name  = "controller.replicas"
    value = "1"
  }

  set {
    name  = "repoServer.replicas"
    value = "1"
  }

  set {
    name  = "server.replicas"
    value = "1"
  }

  # Reduce noise; optional but helps minimal setup
  set {
    name  = "dex.enabled"
    value = "true"
  }

  depends_on = [
    kubernetes_namespace.argocd
  ]
}

#############################################
# ArgoCD Applications via argocd-apps Helm chart
#############################################

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"

  values = [
    yamlencode({
      applications = [
        {
          name        = "cloud-native-ecommerce"
          finalizers  = ["resources-finalizer.argocd.argoproj.io"]
          project     = "default"
          source = {
            repoURL        = var.git_repo_url
            targetRevision = var.git_repo_revision
            path           = "k8s"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "ecommerce"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = ["CreateNamespace=true"]
          }
        },
        {
          name        = "ecommerce-observability"
          finalizers  = ["resources-finalizer.argocd.argoproj.io"]
          project     = "default"
          source = {
            repoURL        = var.git_repo_url
            targetRevision = var.git_repo_revision
            path           = "observability"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "monitoring"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = ["CreateNamespace=true"]
          }
        }
      ]
    })
  ]

  depends_on = [
    helm_release.argocd
  ]
}
