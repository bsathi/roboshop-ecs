#!/bin/bash
# Phase 1 — Step 0: Bootstrap shared ECS Fargate infrastructure for roboshop
#
# Creates: IAM roles, Security Groups, ECS Cluster, Cloud Map namespace +
#          services, ALB, CloudWatch log groups, and writes all IDs to SSM.
#
# Prerequisites:
#   - AWS CLI configured with sufficient permissions
#   - VPC/subnet IDs stored in SSM (run: bash scripts/bootstrap-network.sh)
#
# Usage:
#   ENV=dev bash 00-setup/setup.sh
#   AWS_REGION=ap-south-1 ENV=dev bash 00-setup/setup.sh

set -euo pipefail

ENV=${ENV:-dev}
PROJECT=${PROJECT:-roboshop}
export REGION=${AWS_REGION:-us-east-1}
CLUSTER="${PROJECT}-${ENV}"
DNS_NS="${PROJECT}.local"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")

echo "================================================================"
echo " Roboshop ECS Fargate — Shared Infrastructure Setup"
echo " Cluster  : $CLUSTER"
echo " Namespace: $DNS_NS"
echo " Region   : $REGION"
echo " Account  : $ACCOUNT_ID"
echo "================================================================"
echo ""

# ── Read VPC / Subnet IDs from SSM ──────────────────────────────────────────
VPC_ID=$(aws ssm get-parameter \
  --name "/network/${ENV}/vpc_id" \
  --query Parameter.Value --output text --region "$REGION")
PRIVATE_SUBNETS=$(aws ssm get-parameter \
  --name "/network/${ENV}/private_subnet_ids" \
  --query Parameter.Value --output text --region "$REGION")
PUBLIC_SUBNETS=$(aws ssm get-parameter \
  --name "/network/${ENV}/public_subnet_ids" \
  --query Parameter.Value --output text --region "$REGION")

echo "VPC         : $VPC_ID"
echo "ECS Task SNs: $PRIVATE_SUBNETS"
echo "ALB SNs     : $PUBLIC_SUBNETS"
echo ""

# ── 1. IAM Roles ─────────────────────────────────────────────────────────────
echo "── 1. IAM Roles"

EXEC_ROLE_NAME="${CLUSTER}-ecs-execution-role"
TASK_ROLE_NAME="${CLUSTER}-ecs-task-role"

if ! aws iam get-role --role-name "$EXEC_ROLE_NAME" &>/dev/null; then
  aws iam create-role \
    --role-name "$EXEC_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' > /dev/null
  aws iam attach-role-policy \
    --role-name "$EXEC_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  echo "  ✓ Created: $EXEC_ROLE_NAME"
else
  echo "  ✓ Exists : $EXEC_ROLE_NAME"
fi
EXEC_ROLE_ARN=$(aws iam get-role --role-name "$EXEC_ROLE_NAME" --query Role.Arn --output text)

if ! aws iam get-role --role-name "$TASK_ROLE_NAME" &>/dev/null; then
  aws iam create-role \
    --role-name "$TASK_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' > /dev/null
  echo "  ✓ Created: $TASK_ROLE_NAME"
else
  echo "  ✓ Exists : $TASK_ROLE_NAME"
fi
TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" --query Role.Arn --output text)

aws ssm put-parameter --name "/${PROJECT}/${ENV}/execution_role_arn" --value "$EXEC_ROLE_ARN" --type String --overwrite --region "$REGION" > /dev/null
aws ssm put-parameter --name "/${PROJECT}/${ENV}/task_role_arn"      --value "$TASK_ROLE_ARN" --type String --overwrite --region "$REGION" > /dev/null

# ── 2. Security Groups ────────────────────────────────────────────────────────
echo ""
echo "── 2. Security Groups"

_get_or_create_sg() {
  local name=$1 desc=$2
  local id
  id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null)
  if [[ -z "$id" || "$id" == "None" ]]; then
    id=$(aws ec2 create-security-group \
      --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --query GroupId --output text --region "$REGION")
    echo "  ✓ Created: $name ($id)"
  else
    echo "  ✓ Exists : $name ($id)"
  fi
  echo "$id"
}

ALB_SG_ID=$(_get_or_create_sg      "${CLUSTER}-alb-sg"      "Roboshop ALB - HTTP 80 from internet")
FRONTEND_SG_ID=$(_get_or_create_sg "${CLUSTER}-frontend-sg" "Roboshop frontend nginx container")
APP_SG_ID=$(_get_or_create_sg      "${CLUSTER}-app-sg"      "Roboshop app services")
DATA_SG_ID=$(_get_or_create_sg     "${CLUSTER}-data-sg"     "Roboshop data services")

_ingress_sg() {
  aws ec2 authorize-security-group-ingress \
    --group-id "$1" --protocol tcp --port "$2" --source-group "$3" \
    --region "$REGION" 2>/dev/null || true
}
_ingress_cidr() {
  aws ec2 authorize-security-group-ingress \
    --group-id "$1" --protocol tcp --port "$2" --cidr "$3" \
    --region "$REGION" 2>/dev/null || true
}

# ALB SG: HTTP from anywhere
_ingress_cidr "$ALB_SG_ID"      80    "0.0.0.0/0"

# Frontend SG: port 8080 from ALB only
_ingress_sg   "$FRONTEND_SG_ID" 8080  "$ALB_SG_ID"

# App SG: port 8080 from app-sg (service-to-service) + frontend-sg (nginx → backends)
_ingress_sg   "$APP_SG_ID"      8080  "$APP_SG_ID"
_ingress_sg   "$APP_SG_ID"      8080  "$FRONTEND_SG_ID"

# Data SG: each data port from app-sg only
_ingress_sg   "$DATA_SG_ID"     27017 "$APP_SG_ID"   # MongoDB
_ingress_sg   "$DATA_SG_ID"     6379  "$APP_SG_ID"   # Redis
_ingress_sg   "$DATA_SG_ID"     3306  "$APP_SG_ID"   # MySQL
_ingress_sg   "$DATA_SG_ID"     5672  "$APP_SG_ID"   # RabbitMQ

echo "  ✓ Ingress rules applied"

aws ssm put-parameter --name "/${PROJECT}/${ENV}/alb_sg_id"      --value "$ALB_SG_ID"      --type String --overwrite --region "$REGION" > /dev/null
aws ssm put-parameter --name "/${PROJECT}/${ENV}/frontend_sg_id" --value "$FRONTEND_SG_ID" --type String --overwrite --region "$REGION" > /dev/null
aws ssm put-parameter --name "/${PROJECT}/${ENV}/app_sg_id"      --value "$APP_SG_ID"      --type String --overwrite --region "$REGION" > /dev/null
aws ssm put-parameter --name "/${PROJECT}/${ENV}/data_sg_id"     --value "$DATA_SG_ID"     --type String --overwrite --region "$REGION" > /dev/null

# ── 3. ECS Cluster ────────────────────────────────────────────────────────────
echo ""
echo "── 3. ECS Cluster"

aws ecs create-cluster \
  --cluster-name "$CLUSTER" \
  --settings "name=containerInsights,value=enabled" \
  --capacity-providers FARGATE FARGATE_SPOT \
  --default-capacity-provider-strategy "capacityProvider=FARGATE,weight=1" \
  --region "$REGION" \
  --query 'cluster.clusterName' --output text 2>/dev/null \
  | xargs -I{} echo "  ✓ Cluster: {}"

aws ssm put-parameter --name "/${PROJECT}/${ENV}/cluster_name" --value "$CLUSTER" --type String --overwrite --region "$REGION" > /dev/null

# ── 4. Cloud Map — Private DNS Namespace + Services ───────────────────────────
echo ""
echo "── 4. Cloud Map (${DNS_NS})"

NS_ID=$(aws servicediscovery list-namespaces \
  --query "Namespaces[?Name=='${DNS_NS}'].Id" --output text --region "$REGION")

if [[ -z "$NS_ID" ]]; then
  echo "  Creating namespace (takes ~10s)..."
  OP_ID=$(aws servicediscovery create-private-dns-namespace \
    --name "$DNS_NS" --vpc "$VPC_ID" \
    --query 'OperationId' --output text --region "$REGION")
  while true; do
    STATUS=$(aws servicediscovery get-operation --operation-id "$OP_ID" \
      --query 'Operation.Status' --output text --region "$REGION")
    [[ "$STATUS" == "SUCCESS" ]] && break
    [[ "$STATUS" == "FAIL"    ]] && { echo "ERROR: namespace creation failed"; exit 1; }
    sleep 3
  done
  NS_ID=$(aws servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${DNS_NS}'].Id" --output text --region "$REGION")
fi
echo "  ✓ Namespace: $DNS_NS ($NS_ID)"
aws ssm put-parameter --name "/${PROJECT}/${ENV}/cloudmap_ns_id"   --value "$NS_ID"  --type String --overwrite --region "$REGION" > /dev/null
aws ssm put-parameter --name "/${PROJECT}/${ENV}/cloudmap_ns_name" --value "$DNS_NS" --type String --overwrite --region "$REGION" > /dev/null

# One Cloud Map service per backend component (frontend uses ALB, not Cloud Map)
for COMPONENT in mongodb redis mysql rabbitmq catalogue cart user payment shipping; do
  SD_SVC_ID=$(aws servicediscovery list-services \
    --filters "Name=NAMESPACE_ID,Values=${NS_ID},Condition=EQ" \
    --query "Services[?Name=='${COMPONENT}'].Id" --output text --region "$REGION")

  if [[ -z "$SD_SVC_ID" ]]; then
    SD_SVC_ID=$(aws servicediscovery create-service \
      --name "$COMPONENT" \
      --namespace-id "$NS_ID" \
      --dns-config "NamespaceId=${NS_ID},RoutingPolicy=MULTIVALUE,DnsRecords=[{Type=A,TTL=10}]" \
      --health-check-custom-config "FailureThreshold=1" \
      --query 'Service.Id' --output text --region "$REGION")
  fi

  SD_SVC_ARN=$(aws servicediscovery get-service \
    --id "$SD_SVC_ID" --query 'Service.Arn' --output text --region "$REGION")

  aws ssm put-parameter \
    --name "/${PROJECT}/${ENV}/sd/${COMPONENT}_arn" \
    --value "$SD_SVC_ARN" --type String --overwrite --region "$REGION" > /dev/null

  echo "  ✓ ${COMPONENT}.${DNS_NS}  →  $SD_SVC_ARN"
done

# ── 5. Application Load Balancer ─────────────────────────────────────────────
echo ""
echo "── 5. Application Load Balancer"

# Parse two public subnets for ALB (needs ≥ 2 AZs)
PUBLIC_SN_1=$(echo "$PUBLIC_SUBNETS" | cut -d',' -f1)
PUBLIC_SN_2=$(echo "$PUBLIC_SUBNETS" | cut -d',' -f2)

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${CLUSTER}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${CLUSTER}-alb" \
    --type application \
    --scheme internet-facing \
    --subnets "$PUBLIC_SN_1" "$PUBLIC_SN_2" \
    --security-groups "$ALB_SG_ID" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION")
fi
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")
echo "  ✓ ALB: http://${ALB_DNS}"

TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${CLUSTER}-frontend-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${CLUSTER}-frontend-tg" \
    --protocol HTTP --port 8080 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path "/" \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION")
fi
echo "  ✓ Target Group: ${CLUSTER}-frontend-tg"

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn' --output text --region "$REGION")

if [[ -z "$LISTENER_ARN" ]]; then
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --region "$REGION" > /dev/null
  echo "  ✓ HTTP:80 listener → frontend-tg"
fi

aws ssm put-parameter --name "/${PROJECT}/${ENV}/alb_dns"              --value "$ALB_DNS" --type String --overwrite --region "$REGION" > /dev/null
aws ssm put-parameter --name "/${PROJECT}/${ENV}/alb_target_group_arn" --value "$TG_ARN"  --type String --overwrite --region "$REGION" > /dev/null

# ── 6. CloudWatch Log Groups ──────────────────────────────────────────────────
echo ""
echo "── 6. CloudWatch Log Groups"

for COMPONENT in mongodb redis mysql rabbitmq catalogue cart user payment shipping frontend; do
  aws logs create-log-group \
    --log-group-name "/ecs/${CLUSTER}/${COMPONENT}" \
    --region "$REGION" 2>/dev/null || true
  aws logs put-retention-policy \
    --log-group-name "/ecs/${CLUSTER}/${COMPONENT}" \
    --retention-in-days 7 --region "$REGION" 2>/dev/null || true
done
echo "  ✓ /ecs/${CLUSTER}/<component>  (7-day retention each)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " Setup complete!"
echo ""
echo " Deploy components in this order (data tier first):"
echo "   ENV=${ENV} bash mongodb/deploy.sh"
echo "   ENV=${ENV} bash redis/deploy.sh"
echo "   ENV=${ENV} bash mysql/deploy.sh"
echo "   ENV=${ENV} bash rabbitmq/deploy.sh"
echo "   ENV=${ENV} bash catalogue/deploy.sh"
echo "   ENV=${ENV} bash cart/deploy.sh"
echo "   ENV=${ENV} bash user/deploy.sh"
echo "   ENV=${ENV} bash payment/deploy.sh"
echo "   ENV=${ENV} bash shipping/deploy.sh"
echo "   ENV=${ENV} bash frontend/deploy.sh"
echo ""
echo " Then monitor:"
echo "   ENV=${ENV} bash scripts/status.sh"
echo ""
echo " Application URL:"
echo "   http://${ALB_DNS}"
echo "================================================================"
