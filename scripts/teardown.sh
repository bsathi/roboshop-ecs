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
      # Revoke all inbound rules — cross-SG references block deletion
      INGRESS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions' --output json --region "$REGION" 2>/dev/null || echo "[]")
      if [[ "$INGRESS" != "[]" ]]; then
        aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
          --ip-permissions "$INGRESS" --region "$REGION" 2>/dev/null || true
      fi
      # Revoke all outbound rules — default egress rule can also block deletion
      EGRESS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissionsEgress' --output json --region "$REGION" 2>/dev/null || echo "[]")
      if [[ "$EGRESS" != "[]" ]]; then
        aws ec2 revoke-security-group-egress --group-id "$SG_ID" \
          --ip-permissions "$EGRESS" --region "$REGION" 2>/dev/null || true
      fi
      # Delete any leftover available ENIs referencing this SG (ALB/ECS cleanup lag)
      aws ec2 describe-network-interfaces \
        --filters "Name=group-id,Values=${SG_ID}" "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' \
        --output text --region "$REGION" 2>/dev/null | \
        tr '\t' '\n' | grep -v '^$' | while read ENI_ID; do
          aws ec2 delete-network-interface \
            --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
        done
      if aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null; then
        echo "  ✓ $SG_NAME ($SG_ID)"
      else
        echo "  ✗ Could not delete $SG_NAME ($SG_ID) — delete manually after ENIs are released"
      fi
    else
      echo "  - Skipped (not found): $SG_NAME"
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
SSM_PARAMS=$(aws ssm get-parameters-by-path \
  --path "/${PROJECT}/${ENV}" \
  --recursive \
  --query 'Parameters[*].Name' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$SSM_PARAMS" ]]; then
  read -ra PARAM_ARRAY <<< "$SSM_PARAMS"
  TOTAL=${#PARAM_ARRAY[@]}
  for ((i=0; i<TOTAL; i+=10)); do
    BATCH=("${PARAM_ARRAY[@]:i:10}")
    aws ssm delete-parameters --names "${BATCH[@]}" --region "$REGION" > /dev/null
  done
  echo "  ✓ SSM parameters removed ($TOTAL total)"
else
  echo "  - No SSM parameters found under /${PROJECT}/${ENV}"
fi

echo ""
echo "================================================================"
echo " Teardown complete for: $CLUSTER"
echo "================================================================"
