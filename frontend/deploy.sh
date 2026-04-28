#!/bin/bash
# Deploy Frontend (nginx) to ECS Fargate with ALB
#
# Key difference from other services:
#   - Uses ALB (not Cloud Map) for external access
#   - Injects nginx.conf at container startup via base64 command override
#   - This allows nginx to use Cloud Map DNS names without rebuilding the image
#
# Usage: ENV=dev bash frontend/deploy.sh

set -euo pipefail

ENV=${ENV:-dev}
PROJECT=${PROJECT:-roboshop}
export REGION=${AWS_REGION:-us-east-1}
export CLUSTER="${PROJECT}-${ENV}"
COMPONENT="frontend"
SERVICE_NAME="${CLUSTER}-${COMPONENT}"
SCRIPT_DIR="$(dirname "$0")"

echo "── Deploying ${COMPONENT} → ${CLUSTER}"

export EXEC_ROLE_ARN=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/execution_role_arn" \
  --query Parameter.Value --output text --region "$REGION")
export TASK_ROLE_ARN=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/task_role_arn" \
  --query Parameter.Value --output text --region "$REGION")
FRONTEND_SG_ID=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/frontend_sg_id" \
  --query Parameter.Value --output text --region "$REGION")
PRIVATE_SUBNETS=$(aws ssm get-parameter \
  --name "/network/${ENV}/private_subnet_ids" \
  --query Parameter.Value --output text --region "$REGION")
TG_ARN=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/alb_target_group_arn" \
  --query Parameter.Value --output text --region "$REGION")
ALB_DNS=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/alb_dns" \
  --query Parameter.Value --output text --region "$REGION")

# Base64-encode nginx.conf so it can be injected via container command override.
# The container command writes it to /etc/nginx/nginx.conf before starting nginx.
export NGINX_CONF_B64
NGINX_CONF_B64=$(base64 -w 0 "${SCRIPT_DIR}/nginx.conf" 2>/dev/null \
  || base64 "${SCRIPT_DIR}/nginx.conf" | tr -d '\n')
echo "  nginx.conf encoded (${#NGINX_CONF_B64} chars base64)"

# Register task definition
echo "  Registering task definition..."
TASK_DEF_ARN=$(envsubst '${CLUSTER} ${REGION} ${EXEC_ROLE_ARN} ${TASK_ROLE_ARN} ${NGINX_CONF_B64}' \
  < "${SCRIPT_DIR}/taskdef.json" \
  | aws ecs register-task-definition \
      --cli-input-json file:///dev/stdin \
      --region "$REGION" \
      --query 'taskDefinition.taskDefinitionArn' --output text)
echo "  ✓ $TASK_DEF_ARN"

# Create or update ECS service (with ALB load balancer + 60s grace period)
EXISTING=$(aws ecs describe-services \
  --cluster "$CLUSTER" --services "$SERVICE_NAME" \
  --query 'services[?status==`ACTIVE`].serviceName' --output text --region "$REGION")

if [[ -z "$EXISTING" ]]; then
  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name "$SERVICE_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${PRIVATE_SUBNETS}],securityGroups=[${FRONTEND_SG_ID}],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=frontend,containerPort=8080" \
    --health-check-grace-period-seconds 60 \
    --region "$REGION" > /dev/null
  echo "  ✓ Service created: $SERVICE_NAME"
else
  aws ecs update-service \
    --cluster "$CLUSTER" --service "$SERVICE_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --region "$REGION" > /dev/null
  echo "  ✓ Service updated: $SERVICE_NAME"
fi

echo ""
echo "  Application URL : http://${ALB_DNS}"
echo "  Run 'bash scripts/status.sh' to monitor."
