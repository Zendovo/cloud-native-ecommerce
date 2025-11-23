**E-Commerce Real-Time Analytics Platform — System Design Document**

## **1. System Overview**

This project implements a multi-cloud e-commerce application consisting of six microservices deployed on **AWS EKS** with a **real-time analytics service running on Google Cloud Dataproc (Apache Flink)**. The application supports product browsing, cart activity, customer management, and order creation, while also collecting user interaction events to generate real-time analytics.

The solution uses:

- **AWS** as the primary cloud (Kubernetes workloads, storage, messaging, serverless function)
- **GCP** for analytical compute workloads

All infrastructure is provisioned through **Terraform**, and all microservice deployments are managed via **GitOps (ArgoCD)** with no direct `kubectl apply`.

A Kafka-based streaming pipeline with Flink performs **stateful 1-minute window analytics** to count unique shoppers per product, enabling real-time dashboards.

The architecture demonstrates scalability, elasticity, observability, event-driven processing, and multi-cloud interoperability.

---

## **3. Microservices Architecture**

| Service Name                             | Purpose                                     | Deployment   | Communication               | Storage        | Autoscaling |
| ---------------------------------------- | ------------------------------------------- | ------------ | --------------------------- | -------------- | ----------- |
| **API Gateway Service**                  | Public REST entrypoint for all clients      | AWS EKS      | REST                        | None           | Yes         |
| **Customer Service**                     | Manages customer data & authentication      | AWS EKS      | REST                        | RDS PostgreSQL | No          |
| **Product Catalog Service**              | Manages products, pricing, categories       | AWS EKS      | REST                        | RDS PostgreSQL | No          |
| **Order Service**                        | Order creation & state management           | AWS EKS      | REST + optional Kafka event | RDS PostgreSQL | No          |
| **Activity Service**                     | Collects user events and publishes to Kafka | AWS EKS      | REST → Kafka                | None           | Yes         |
| **Analytics Processing Service (Flink)** | Stateful unique-user-per-minute analytics   | GCP Dataproc | Kafka ↔ DynamoDB           | DynamoDB       | N/A         |

### Serverless Component

| Function                     | Trigger        | Purpose                                          |
| ---------------------------- | -------------- | ------------------------------------------------ |
| `product_bulk_import_lambda` | S3 file upload | Parses CSVs and updates product catalog via REST |

---

## **4. Data Flow Summary**

| Stage                      | Trigger                       | Processing                                          | Output                       |
| -------------------------- | ----------------------------- | --------------------------------------------------- | ---------------------------- |
| Customer interacts with UI | HTTP request                  | Routed through API Gateway                          | Response                     |
| Customer activity event    | REST call to Activity Service | Published to Kafka topic `ecom-raw-events`          | Kafka                        |
| Streaming analytics        | Kafka consumer by Flink       | Tumbling window aggregation (1-min unique shoppers) | Kafka topic + DynamoDB write |
| Dashboard fetch            | UI/monitoring tool            | API Gateway → DynamoDB                              | JSON response                |

---

## **5. Communication Protocols**

| Type                         | Used By                   | Technology      |
| ---------------------------- | ------------------------- | --------------- |
| Inter-service communication  | All backend services      | REST over HTTP  |
| Asynchronous event streaming | Activity → Analytics      | Kafka (AWS MSK) |
| Frontend communication       | Web clients → API Gateway | HTTPS           |

---

## **6. Storage Model**

| Storage                  | Purpose                            | Used By                         |
| ------------------------ | ---------------------------------- | ------------------------------- |
| **AWS S3**               | Raw product uploads & static files | Lambda                          |
| **AWS RDS (PostgreSQL)** | Customers, products, orders        | Customer/Product/Order Services |
| **DynamoDB**             | Real-time computed analytics       | Flink + Analytics queries       |

---

## **7. Scaling Strategy**

- **Kubernetes Horizontal Pod Autoscalers (HPA)** enabled for:
  - API Gateway Service
  - Activity Service

HPA triggers when CPU > 60% or memory threshold exceeded.

Kafka and Flink can naturally scale horizontally to handle increased streaming load.

---

## **8. Deployment & CI/CD Strategy**

- All environments are declared in **Terraform**.
- Microservices are deployed via **ArgoCD GitOps pipeline**:

```
Git Commit → ArgoCD detects change → Applies manifests → EKS update
```

No manual deployment (`kubectl apply` forbidden).

---

## **9. Observability Strategy**

| Component  | Tool                             | Location                       |
| ---------- | -------------------------------- | ------------------------------ |
| Metrics    | Prometheus + Grafana             | AWS EKS                        |
| Logs       | FluentBit → Google Cloud Logging | Unified across AWS + GCP       |
| Dashboards | Grafana                          | Accessible to engineering team |

Metrics tracked include:

- Request latency
- Error rate
- Throughput (requests/sec)
- Kafka consumer lag
- Pod count vs HPA target metrics

---

## **10. Load Testing Strategy**

- Tool: **k6**
- Target endpoints:
  - `/products`
  - `/cart/add`
  - `/orders`

- Purpose:
  - Verify HPA scale-out behavior
  - Observe Kafka throughput impact
  - Confirm latency stays within SLA (<300ms avg)

---

## **11. API Examples**

### Example — POST `/activity/event`

```json
{
  "user_id": "U109",
  "product_id": "P301",
  "event_type": "VIEW_PRODUCT",
  "timestamp": "2025-11-23T12:40:09Z"
}
```

### Analytics Output (from DynamoDB)

```json
{
  "product_id": "P301",
  "window_start": "2025-11-23T12:40:00Z",
  "unique_user_count": 87
}
```

---

## **12. Technology Stack Summary**

| Category       | Technology                            |
| -------------- | ------------------------------------- |
| Infrastructure | Terraform                             |
| Compute        | AWS EKS, AWS Lambda, Dataproc (Flink) |
| Messaging      | AWS MSK (Kafka)                       |
| Storage        | S3, RDS Postgres, DynamoDB            |
| Deployment     | ArgoCD (GitOps)                       |
| Observability  | Prometheus, Grafana, Cloud Logging    |
| Testing        | k6                                    |

---

## **13. Risks & Mitigation**

| Risk                       | Impact                               | Mitigation                             |
| -------------------------- | ------------------------------------ | -------------------------------------- |
| Cross-cloud latency        | Could affect stream jobs             | Kafka batch optimization, async writes |
| Autoscaling delay          | Burst traffic may overwhelm services | Increased pod minimum count            |
| Schema evolution in events | Analytics errors                     | Schema registry + versioning           |

---
