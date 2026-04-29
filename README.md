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

---

## Operational Runbook

### Stop all services (save cost)

```bash
for svc in frontend shipping payment user cart catalogue rabbitmq mysql redis mongodb; do
  aws ecs update-service \
    --cluster roboshop-dev \
    --service roboshop-dev-${svc} \
    --desired-count 0 \
    --region us-east-1 > /dev/null && echo "Stopped: $svc"
done
```

Stop in reverse dependency order (frontend first, data tier last).

### Start all services

```bash
for svc in mongodb redis mysql rabbitmq catalogue cart user payment shipping frontend; do
  aws ecs update-service \
    --cluster roboshop-dev \
    --service roboshop-dev-${svc} \
    --desired-count 1 \
    --region us-east-1 > /dev/null && echo "Started: $svc"
done
```

> **Important:** Wait ~90 seconds after starting MySQL before starting shipping. MySQL runs init scripts (`app-user.sql`, `master-data.sql`) that take ~80 seconds on first boot. If shipping starts before MySQL is ready, Spring Boot fails to initialise the HikariCP connection pool and exits. ECS will restart it automatically — but it's cleaner to wait.

### Redeploy a single service after code/config change

```bash
ENV=dev bash <component>/deploy.sh
# e.g.
ENV=dev bash shipping/deploy.sh
ENV=dev bash frontend/deploy.sh
```

The deploy scripts handle create vs update automatically and now always set `--desired-count 1`.

### Monitor service health

```bash
bash scripts/status.sh

# Tail logs for a specific service
aws logs tail /ecs/roboshop-dev/shipping --follow --region us-east-1
aws logs tail /ecs/roboshop-dev/mysql    --follow --region us-east-1
```

---

## Troubleshooting — Issues Encountered & Fixes

This section documents every real issue hit during initial deployment, the root cause, and the fix applied. Future deployments should not hit these — but if they do, this is the reference.

---

### 1. `update-service` does not restore desired count after stop

**Symptom:** After stopping all services (desired-count=0) and running deploy scripts, all services remain at `Running=0, Desired=0`.

**Root cause:** `aws ecs update-service` does not change `desiredCount` unless explicitly passed. If a service was stopped with `--desired-count 0`, redeploying without `--desired-count` leaves it at 0.

**Fix:** Added `--desired-count 1` to the `update-service` branch in all 10 `deploy.sh` files.

```bash
# Before (broken)
aws ecs update-service \
  --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "$TASK_DEF_ARN" \
  --region "$REGION"

# After (fixed)
aws ecs update-service \
  --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --task-definition "$TASK_DEF_ARN" \
  --desired-count 1 \        # <-- must be explicit
  --region "$REGION"
```

**Immediate recovery if already stopped:**
```bash
for svc in mongodb redis mysql rabbitmq catalogue cart user payment shipping frontend; do
  aws ecs update-service --cluster roboshop-dev \
    --service roboshop-dev-${svc} \
    --desired-count 1 --region us-east-1 > /dev/null && echo "Started: $svc"
done
```

---

### 2. Container health check fails on Alpine-based images (502 Bad Gateway)

**Symptom:** catalogue, cart, user, payment, shipping services show `Running=1` in ECS but return 502 from the frontend. CloudWatch shows the container being killed and restarted every ~75 seconds.

**Root cause:** The `healthCheck` block in `taskdef.json` used `curl -sf http://localhost:8080/health` — but the Node.js/Python service images are Alpine-based and `curl` is not installed. The health check command always exits non-zero, so ECS kills and restarts the container after 3 retries × 15s interval + 30s startPeriod.

**Fix:** Removed `healthCheck` entirely from all 5 app-tier task definitions (catalogue, cart, user, payment, shipping). ECS marks the container healthy based on process exit code alone.

```json
// REMOVED from taskdef.json for all app services:
"healthCheck": {
  "command":     ["CMD-SHELL", "curl -sf http://localhost:8080/health || exit 1"],
  "interval":    15,
  "timeout":     5,
  "retries":     3,
  "startPeriod": 30
}
```

**Lesson:** When adding ECS container health checks, verify the tool (`curl`, `wget`, etc.) is actually present in the image. For Alpine images, prefer `CMD-SHELL` with `wget -qO- ...` or use `CMD` with a language-native check built into the app.

---

### 3. ALB health check — `Target.NotInUse` (AZ mismatch)

**Symptom:** Frontend task runs (`Running=1`) but ALB health check shows:
```
Target.NotInUse: Target is in an Availability Zone that is not enabled for the load balancer
```
The ALB returns 503 for all requests.

**Root cause:** `bootstrap-network.sh` split the VPC subnets into `PUBLIC_SUBNETS` (used for ALB) and `PRIVATE_SUBNETS` (used for ECS tasks). These covered **different AZs**. The ALB had subnets in us-east-1b and us-east-1d; ECS tasks landed in us-east-1a and us-east-1c. Since the ALB had no subnet in the task's AZ, it could not route to it.

**Fix:** When creating the ALB in `setup.sh`, attach **all VPC subnets** (not just the public ones). The ALB needs a subnet in every AZ where ECS tasks can potentially land.

```bash
# Get all subnets in the VPC
ALL_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[*].SubnetId' --output text --region "$REGION")

# Add to existing ALB after the fact
aws elbv2 set-subnets \
  --load-balancer-arn "$ALB_ARN" \
  --subnets $ALL_SUBNETS \
  --region "$REGION"
```

**Lesson:** In ECS Fargate with an ALB, the ALB must have at least one subnet in every AZ that the ECS service can schedule tasks into. ECS does not restrict which AZ a task lands in, so it is safer to attach all available subnets to the ALB.

---

### 4. Frontend nginx — `Permission denied` writing pid file

**Symptom:** Frontend container logs repeatedly show:
```
nginx: [alert] unlink() "/run/nginx.pid" failed (13: Permission denied)
```
Container either fails to start or starts but is unstable.

**Root cause:** The `bsathi2020/frontend:v1` nginx binary was compiled with `/run/nginx.pid` as the default pid path. On startup, nginx attempts to unlink a stale pid file from the image layer at `/run/nginx.pid`, owned by root. A non-root container user cannot delete it.

**Fixes applied (all three needed together):**

1. **`frontend/nginx.conf`** — redirect pid to a writable location:
   ```nginx
   pid /tmp/nginx.pid;
   ```

2. **`frontend/taskdef.json`** — run container as root to bypass the permission issue:
   ```json
   "user": "0"
   ```

3. **`frontend/deploy.sh`** — write nginx.conf to `/tmp` at startup (not `/etc/nginx`):
   ```json
   "command": ["sh", "-c", "echo '${NGINX_CONF_B64}' | base64 -d > /tmp/nginx.conf && nginx -c /tmp/nginx.conf -g 'daemon off;'"]
   ```

**Lesson:** The `[alert] unlink()` message is non-fatal — nginx continues running. Do not spend time chasing it as the root cause of a broken service. Always check ALB target health and CloudWatch logs separately to find the real failure.

---

### 5. Shipping service fails to connect to MySQL on startup (race condition)

**Symptom:** Shipping service logs show:
```
java.net.ConnectException: Connection refused
HikariPool-1 - Exception during pool initialization.
Could not create connection to database server. Attempted reconnect 3 times. Giving up.
```
The "Enter Location" autocomplete returns no results.

**Root cause:** All services were started simultaneously. MySQL's Docker entrypoint runs two init scripts (`app-user.sql`, `master-data.sql`) that together take ~80 seconds before MySQL starts listening on port 3306. Shipping's Spring Boot context initialises HikariCP immediately and tries to connect before MySQL is ready. After 3 retries it exits. ECS detects the exit and restarts the task — by then MySQL is ready, so the second attempt succeeds.

**Current behaviour:** ECS handles this automatically via task restart. The shipping service comes up healthy on the second attempt. No manual intervention needed.

**Recommended improvement:** Add a startup delay or wait loop to the shipping container command, or deploy data tier services and wait for `Running=1` before deploying the app tier.

```bash
# Safest sequence: confirm MySQL is running before deploying shipping
bash scripts/status.sh  # verify mysql Running=1
ENV=dev bash shipping/deploy.sh
```

---

### 6. "Enter Location" field in checkout — not a dropdown

**Symptom:** After selecting a country on the checkout/shipping page, the "Enter Location" field appears empty and does not populate with cities.

**Root cause:** This is not a bug. The "Enter Location" field is a **type-ahead autocomplete input**, not a `<select>` dropdown. It requires the user to start typing. The frontend JavaScript calls:
```
GET /api/shipping/match/{country_code}/{typed_term}
```
only when the user types characters into the field.

**How it works:**
1. Select a country from the dropdown → the location field is enabled
2. Start **typing** a city name (e.g., "del" for Delhi, "mum" for Mumbai)
3. Matching cities appear as suggestions
4. Select a city from the suggestions

**API endpoints used by the shipping page:**

| Endpoint | Purpose |
|----------|---------|
| `GET /api/shipping/codes` | Loads country dropdown on page load |
| `GET /api/shipping/match/{code}/{term}` | Returns cities matching typed term |
| `GET /api/shipping/calc/{uuid}` | Calculates shipping cost for selected city |
| `POST /api/shipping/confirm/{userid}` | Confirms shipping and moves to payment |

---

## End-to-End Application Flow (Verified)

| Step | Action | Services involved |
|------|--------|------------------|
| 1 | Browse catalogue | frontend → catalogue → mongodb |
| 2 | Add item to cart | frontend → cart → redis, catalogue |
| 3 | Register / Login | frontend → user → mongodb, redis |
| 4 | Go to checkout | frontend → cart → redis |
| 5 | Select country, type city | frontend → shipping → mysql |
| 6 | Calculate shipping | frontend → shipping |
| 7 | Confirm shipping | frontend → shipping → cart |
| 8 | Pay | frontend → payment → cart, user, rabbitmq |

All steps verified working in production deployment on ECS Fargate (April 2026).
