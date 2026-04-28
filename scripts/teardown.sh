#!/bin/bash
# Tear down all Roboshop ECS Fargate resources
#
# Deletes (in order): ECS services → ECS cluster → ALB → target group →
#   Cloud Map services → Cloud Map namespace → Security Groups → IAM roles →
#   CloudWatch log groups → SSM parameters
#
# Usage: ENV=dev bash scripts/teardown.sh
# WARNING: This is destructive and irreversible.

set -euo pipefail

ENV=${ENV:-dev}
PROJECT=${PROJECT:-roboshop}
REGION=${AWS_REGION:-us-east-1}
CLUSTER="${PROJECT}-${ENV}"
DNS_NS="${PROJECT}.local"

echo "================================================================"
echo " WARNING: This will delete ALL roboshop-ecs resources for:"
echo " Cluster : $CLUSTER"
echo " Region  : $REGION"
echo "================================================================"
read -rp "Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "Aborted."; exit 0; }

# ── 1. Scale all services to 0 and delete ────────────────────────────────────
echo ""
echo "── 1. Deleting ECS Services"

SERVICES=(mongodb redis mysql rabbitmq catalogue cart user payment shipping frontend)
for COMPONENT in "${SERVICES[@]}"; do
  SERVICE_NAME="${CLUSTER}-${COMPONENT}"
  STATUS=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE_NAME" \
    --query 'services[0].status' --output text --region "$REGION" 2>/dev/null || echo "MISSING")

  if [[ "$STATUS" == "ACTIVE" ]]; then
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
      --desired-count 0 --region "$REGION" > /dev/null
    aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE_NAME" \
      --force --region "$REGION" > /dev/null
    echo "  ✓ Deleted: $SERVICE_NAME"
  else
    echo "  - Skipped (not found): $SERVICE_NAME"
  fi
done

# ── 2. Delete ECS Cluster ─────────────────────────────────────────────────────
echo ""
echo "── 2. Deleting ECS Cluster"
aws ecs delete-cluster --cluster "$CLUSTER" --region "$REGION" > /dev/null 2>&1 || true
echo "  ✓ $CLUSTER"

# ── 3. Delete ALB + Target Group ─────────────────────────────────────────────
echo ""
echo "── 3. Deleting ALB"
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${CLUSTER}-alb" --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text --region "$REGION" 2>/dev/null || echo "")
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION"
  echo "  ✓ ALB deleted (target group auto-removed)"
  sleep 10
fi

TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${CLUSTER}-frontend-tg" --query 'TargetGroups[0].TargetGroupArn' \
  --output text --region "$REGION" 2>/dev/null || echo "")
if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION"
  echo "  ✓ Target group deleted"
fi

# ── 4. Delete Cloud Map Services + Namespace ─────────────────────────────────
echo ""
echo "── 4. Deleting Cloud Map"
NS_ID=$(aws servicediscovery list-namespaces \
  --query "Namespaces[?Name=='${DNS_NS}'].Id" --output text --region "$REGION")

if [[ -n "$NS_ID" ]]; then
  for COMPONENT in mongodb redis mysql rabbitmq catalogue cart user payment shipping; do
    SD_SVC_ID=$(aws servicediscovery list-services \
      --filters "Name=NAMESPACE_ID,Values=${NS_ID},Condition=EQ" \
      --query "Services[?Name=='${COMPONENT}'].Id" --output text --region "$REGION")
    if [[ -n "$SD_SVC_ID" ]]; then
      aws servicediscovery delete-service --id "$SD_SVC_ID" --region "$REGION" > /dev/null
      echo "  ✓ Service deleted: ${COMPONENT}.${DNS_NS}"
    fi
  done
  aws servicediscovery delete-namespace --id "$NS_ID" --region "$REGION" > /dev/null
  echo "  ✓ Namespace deleted: $DNS_NS"
fi

# ── 5. Delete Security Groups ─────────────────────────────────────────────────
echo ""
echo "── 5. Deleting Security Groups"

VPC_ID=$(aws ssm get-parameter --name "/network/${ENV}/vpc_id" \
  --query Parameter.Value --output text --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$VPC_ID" ]]; then
  for SG_NAME in "${CLUSTER}-alb-sg" "${CLUSTER}-frontend-sg" "${CLUSTER}-app-sg" "${CLUSTER}-data-sg"; do
    SG_ID=$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
      --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
    if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
      aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
      echo "  ✓ $SG_NAME ($SG_ID)"
    fi
  done
fi

# ── 6. Delete IAM Roles ───────────────────────────────────────────────────────
echo ""
echo "── 6. Deleting IAM Roles"

EXEC_ROLE="${CLUSTER}-ecs-execution-role"
TASK_ROLE="${CLUSTER}-ecs-task-role"

if aws iam get-role --role-name "$EXEC_ROLE" &>/dev/null; then
  aws iam detach-role-policy --role-name "$EXEC_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  aws iam delete-role --role-name "$EXEC_ROLE"
  echo "  ✓ $EXEC_ROLE"
fi
if aws iam get-role --role-name "$TASK_ROLE" &>/dev/null; then
  aws iam delete-role --role-name "$TASK_ROLE"
  echo "  ✓ $TASK_ROLE"
fi

# ── 7. Delete CloudWatch Log Groups ───────────────────────────────────────────
echo ""
echo "── 7. Deleting CloudWatch Log Groups"
for COMPONENT in mongodb redis mysql rabbitmq catalogue cart user payment shipping frontend; do
  aws logs delete-log-group \
    --log-group-name "/ecs/${CLUSTER}/${COMPONENT}" \
    --region "$REGION" 2>/dev/null || true
done
echo "  ✓ /ecs/${CLUSTER}/<all components>"

# ── 8. Clean up SSM Parameters ────────────────────────────────────────────────
echo ""
echo "── 8. Removing SSM Parameters"
aws ssm delete-parameters \
  --names \
    "/${PROJECT}/${ENV}/cluster_name" \
    "/${PROJECT}/${ENV}/execution_role_arn" \
    "/${PROJECT}/${ENV}/task_role_arn" \
    "/${PROJECT}/${ENV}/alb_sg_id" \
    "/${PROJECT}/${ENV}/frontend_sg_id" \
    "/${PROJECT}/${ENV}/app_sg_id" \
    "/${PROJECT}/${ENV}/data_sg_id" \
    "/${PROJECT}/${ENV}/cloudmap_ns_id" \
    "/${PROJECT}/${ENV}/cloudmap_ns_name" \
    "/${PROJECT}/${ENV}/alb_dns" \
    "/${PROJECT}/${ENV}/alb_target_group_arn" \
    "/${PROJECT}/${ENV}/sd/mongodb_arn" \
    "/${PROJECT}/${ENV}/sd/redis_arn" \
    "/${PROJECT}/${ENV}/sd/mysql_arn" \
    "/${PROJECT}/${ENV}/sd/rabbitmq_arn" \
    "/${PROJECT}/${ENV}/sd/catalogue_arn" \
    "/${PROJECT}/${ENV}/sd/cart_arn" \
    "/${PROJECT}/${ENV}/sd/user_arn" \
    "/${PROJECT}/${ENV}/sd/payment_arn" \
    "/${PROJECT}/${ENV}/sd/shipping_arn" \
  --region "$REGION" > /dev/null 2>&1 || true
echo "  ✓ SSM parameters removed"

echo ""
echo "================================================================"
echo " Teardown complete for: $CLUSTER"
echo "================================================================"
