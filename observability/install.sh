#!/bin/bash

set -e

echo "Installing Prometheus and Grafana..."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Prometheus..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.enabled=true \
  --set grafana.adminPassword=admin123 \
  --wait

echo "Installing FluentBit..."
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace monitoring \
  --set backend.type=gcp \
  --set backend.gcp.projectId=${GCP_PROJECT_ID:-"your-project-id"} \
  --wait

echo "Observability stack installed successfully!"
echo "Access Grafana:"
echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  Username: admin"
echo "  Password: admin123"
