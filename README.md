# roboshop-ecs

Roboshop e-commerce application running on **AWS ECS Fargate** — the cloud-native equivalent of [k8-roboshop](https://github.com/bsathi/k8-roboshop), without Kubernetes.

Each component has its own folder with a `taskdef.json` (analogous to Kubernetes `manifest.yaml`) and a `deploy.sh` script.

> **No persistent storage (EFS/EBS).** Data services (MongoDB, MySQL) use container-local ephemeral storage — suitable for dev/test. Data is lost on task restart.

---

## Architecture

```
Internet
   │
   │ HTTP:80
   ▼
┌──────────────────────────────────────────┐
│           ALB (internet-facing)          │
│       roboshop-dev-alb                   │
└──────────────────┬───────────────────────┘
                   │ HTTP:8080
                   ▼
         ┌─────────────────┐
         │    Frontend     │  ← nginx (bsathi2020/frontend:v1)
         │  frontend-sg    │    nginx.conf injected at startup
         └────────┬────────┘    via base64 command override
                  │
     ┌────────────┼────────────────────────┐
     │ HTTP:8080  │                        │
     ▼            ▼                        ▼
┌──────────┐ ┌──────────┐   ┌──────────┐ ┌──────────┐
│catalogue │ │   cart   │   │   user   │ │ payment  │
└────┬─────┘ └──┬───┬───┘   └──┬───┬──┘ └────┬─────┘
     │          │   │          │   │           │      ┌──────────┐
     │          │   │          │   │           │      │ shipping │
     │          │   │          │   │           │      └────┬─────┘
     │          │   │          │   │           │           │
     │  27017   │   │  6379    │   │   5672    │    3306   │
     ▼          ▼   ▼          ▼   ▼           ▼           ▼
┌─────────┐ ┌──────┐        ┌──────────┐   ┌────────────────┐
│ MongoDB │ │Redis │        │ RabbitMQ │   │     MySQL      │
└─────────┘ └──────┘        └──────────┘   └────────────────┘

All internal traffic via Cloud Map DNS: <service>.roboshop.local
Security groups: app-sg (microservices) ↔ data-sg (databases)
```

---

## K8s → ECS Fargate Mapping

| Kubernetes | ECS Fargate | Notes |
|------------|-------------|-------|
| Namespace | ECS Cluster | `roboshop-dev` |
| Deployment | Task Definition | `taskdef.json` per component |
| ClusterIP Service | Cloud Map (Service Discovery) | DNS: `component.roboshop.local` |
| LoadBalancer Service | ALB + Target Group | Frontend only |
| ConfigMap (nginx.conf) | base64 command override | Injected at container startup |
| `kubectl apply -f manifest.yaml` | `bash deploy.sh` | Per-component deploy |
| `kubectl scale deployment` | `bash scripts/scale.sh` | Same concept |
| kube-dns | AWS Cloud Map | Private DNS namespace `roboshop.local` |

---

## Project Structure

```
roboshop-ecs/
├── 00-setup/
│   └── setup.sh            ← shared infra (IAM, SGs, cluster, Cloud Map, ALB)
├── mongodb/
│   ├── taskdef.json        ← like manifest.yaml
│   └── deploy.sh
├── redis/
├── mysql/
├── rabbitmq/
├── catalogue/
├── cart/
├── user/
├── payment/
├── shipping/
├── frontend/
│   ├── taskdef.json
│   ├── nginx.conf          ← upstream config with Cloud Map DNS names
│   └── deploy.sh
└── scripts/
    ├── bootstrap-network.sh  ← pre-load VPC/subnet IDs into SSM
    ├── status.sh             ← show all service states + ALB URL
    ├── scale.sh              ← scale any service up/down
    └── teardown.sh           ← remove all resources
```

---

## Service Dependency Order

```
Data Tier (deploy first):
  mongodb → redis → mysql → rabbitmq

App Tier (deploy after data tier):
  catalogue (needs: mongodb)
  cart      (needs: redis, catalogue)
  user      (needs: mongodb, redis)
  payment   (needs: cart, user, rabbitmq)
  shipping  (needs: cart, mysql)

Frontend (deploy last):
  frontend  (proxies to all app services via nginx)
```

---

## Fargate Task Sizing

| Component | CPU | Memory | Why |
|-----------|-----|--------|-----|
| mongodb   | 512 | 1024 MB | Data service |
| redis     | 256 | 512 MB  | In-memory cache |
| mysql     | 512 | 1024 MB | Data service |
| rabbitmq  | 256 | 512 MB  | Message queue |
| catalogue | 256 | 512 MB  | Node.js service |
| cart      | 256 | 512 MB  | Node.js service |
| user      | 256 | 512 MB  | Node.js service |
| payment   | 256 | 512 MB  | Python service |
| shipping  | 512 | 1024 MB | Java service (JVM heap) |
| frontend  | 256 | 512 MB  | nginx |

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| AWS CLI v2 | All AWS operations |
| `envsubst` | Variable substitution in taskdef.json (from `gettext` package) |
| `base64` | Encode nginx.conf for frontend injection |
| `jq` (optional) | Useful for inspecting AWS CLI JSON output |

```bash
# macOS
brew install gettext jq

# Ubuntu / Amazon Linux
sudo apt-get install -y gettext jq
# or
sudo yum install -y gettext jq
```

Verify AWS CLI is configured:
```bash
aws sts get-caller-identity
```

---

## Phase 1 Deployment Guide (AWS CLI)

### Step 0 — Bootstrap network config in SSM

Run once per environment. Your VPC and subnets must already exist.

```bash
bash scripts/bootstrap-network.sh dev \
  vpc-0abc123def456 \
  "subnet-private1,subnet-private2" \
  "subnet-public1,subnet-public2"
```

Stores in SSM Parameter Store:
- `/network/dev/vpc_id`
- `/network/dev/private_subnet_ids`
- `/network/dev/public_subnet_ids`

---

### Step 1 — Create shared infrastructure

```bash
ENV=dev bash 00-setup/setup.sh
```

Creates and stores in SSM:

| Resource | SSM Parameter |
|----------|--------------|
| ECS Cluster `roboshop-dev` | `/roboshop/dev/cluster_name` |
| Execution IAM Role | `/roboshop/dev/execution_role_arn` |
| Task IAM Role | `/roboshop/dev/task_role_arn` |
| ALB SG | `/roboshop/dev/alb_sg_id` |
| Frontend SG | `/roboshop/dev/frontend_sg_id` |
| App SG (microservices) | `/roboshop/dev/app_sg_id` |
| Data SG (databases) | `/roboshop/dev/data_sg_id` |
| Cloud Map NS `roboshop.local` | `/roboshop/dev/cloudmap_ns_id` |
| Cloud Map service ARNs | `/roboshop/dev/sd/<component>_arn` |
| ALB DNS name | `/roboshop/dev/alb_dns` |
| Frontend Target Group ARN | `/roboshop/dev/alb_target_group_arn` |

---

### Step 2 — Deploy data tier

```bash
ENV=dev bash mongodb/deploy.sh
ENV=dev bash redis/deploy.sh
ENV=dev bash mysql/deploy.sh
ENV=dev bash rabbitmq/deploy.sh
```

Each script:
1. Reads shared config from SSM
2. Substitutes `${CLUSTER}`, `${REGION}`, `${EXEC_ROLE_ARN}`, `${TASK_ROLE_ARN}` in `taskdef.json`
3. Registers task definition with `aws ecs register-task-definition`
4. Creates (or updates) ECS service with Cloud Map service discovery

---

### Step 3 — Deploy app tier

Wait until data services show `Running=1` before proceeding:
```bash
ENV=dev bash scripts/status.sh
```

Then deploy:
```bash
ENV=dev bash catalogue/deploy.sh
ENV=dev bash cart/deploy.sh
ENV=dev bash user/deploy.sh
ENV=dev bash payment/deploy.sh
ENV=dev bash shipping/deploy.sh
```

---

### Step 4 — Deploy frontend

```bash
ENV=dev bash frontend/deploy.sh
```

This script base64-encodes `frontend/nginx.conf` and injects it as a container command override. nginx starts with Cloud Map DNS upstream names (`catalogue.roboshop.local`, etc.) already configured.

---

### Step 5 — Verify

```bash
ENV=dev bash scripts/status.sh
```

Expected output: all 10 services show `Running=1`.

Open the application:
```
http://<ALB-DNS>
```

Tail logs for any service:
```bash
aws logs tail /ecs/roboshop-dev/catalogue --follow --region us-east-1
aws logs tail /ecs/roboshop-dev/cart      --follow --region us-east-1
aws logs tail /ecs/roboshop-dev/frontend  --follow --region us-east-1
```

---

## Scaling

```bash
# Scale catalogue to 3 replicas
ENV=dev bash scripts/scale.sh catalogue 3

# Scale back to 1
ENV=dev bash scripts/scale.sh catalogue 1

# Stop a service (zero cost)
ENV=dev bash scripts/scale.sh catalogue 0
```

---

## Cost Estimate (us-east-1, 2024)

Fargate pricing: `$0.04048/vCPU-hr` + `$0.004445/GB-hr`

| Scenario | ~Monthly Cost |
|----------|--------------|
| Always-on (24/7, 10 services) | ~$140/month |
| Business hours (8h/day Mon-Fri) | ~$46/month |
| ALB (always-on) | ~$16/month |

> **Tip:** Stop all services when not in use:
> ```bash
> for svc in mongodb redis mysql rabbitmq catalogue cart user payment shipping frontend; do
>   ENV=dev bash scripts/scale.sh $svc 0
> done
> ```

---

## Teardown

Removes all resources created by this project:

```bash
ENV=dev bash scripts/teardown.sh
```

> Note: VPC, subnets, and `/network/...` SSM parameters are NOT deleted (they existed before this project).

---

## Key Design Decisions

### Service Discovery — Cloud Map vs. Kubernetes DNS

| | Kubernetes | ECS Fargate |
|-|-----------|-------------|
| DNS resolver | kube-dns | AWS Cloud Map → Route 53 |
| Short name | `mongodb` | not supported |
| Full name | `mongodb.roboshop.svc.cluster.local` | `mongodb.roboshop.local` |
| Auto-registration | Service + Endpoints | ECS service_registries block |

The K8s manifests use short service names (e.g., `REDIS_HOST: redis`). ECS with Cloud Map requires FQDN (`redis.roboshop.local`). All `taskdef.json` env vars in this repo use the Cloud Map FQDNs.

### Frontend nginx.conf Injection

The original K8s manifest mounts nginx.conf via ConfigMap:
```yaml
volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/nginx.conf
    subPath: nginx.conf
```

ECS Fargate has no ConfigMap equivalent without EFS. Instead, the container `command` is overridden to decode a base64-encoded nginx.conf and write it before starting nginx:
```json
"command": ["sh", "-c", "echo 'BASE64...' | base64 -d > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]
```

The `frontend/deploy.sh` computes this at deploy time from `frontend/nginx.conf`.

### No Persistent Storage

MongoDB, MySQL: data stored in container ephemeral storage only. On task restart (e.g., scaling, health check failure), all data is lost. This is intentional for Phase 1 (dev/learning). Phase 2 (Terraform) can optionally add EFS for persistence.

---

## Phase 2 — Terraform (Coming Next)

Phase 2 will wrap everything in Terraform modules, mirroring this folder structure, following the same modular pattern as `terraform-roboshop-component`.
