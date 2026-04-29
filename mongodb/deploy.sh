#!/bin/bash
# Deploy MongoDB to ECS Fargate
# Usage: ENV=dev bash mongodb/deploy.sh

set -euo pipefail

ENV=${ENV:-dev}
PROJECT=${PROJECT:-roboshop}
export REGION=${AWS_REGION:-us-east-1}
export CLUSTER="${PROJECT}-${ENV}"
COMPONENT="mongodb"
SERVICE_NAME="${CLUSTER}-${COMPONENT}"

echo "── Deploying ${COMPONENT} → ${CLUSTER}"

# Read shared config from SSM
export EXEC_ROLE_ARN=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/execution_role_arn" \
  --query Parameter.Value --output text --region "$REGION")
export TASK_ROLE_ARN=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/task_role_arn" \
  --query Parameter.Value --output text --region "$REGION")
DATA_SG_ID=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/data_sg_id" \
  --query Parameter.Value --output text --region "$REGION")
PRIVATE_SUBNETS=$(aws ssm get-parameter \
  --name "/network/${ENV}/private_subnet_ids" \
  --query Parameter.Value --output text --region "$REGION")
SD_ARN=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/sd/${COMPONENT}_arn" \
  --query Parameter.Value --output text --region "$REGION")

# Register task definition (substitutes ${CLUSTER}, ${REGION}, ${EXEC_ROLE_ARN}, ${TASK_ROLE_ARN})
echo "  Registering task definition..."
TASK_JSON=$(envsubst '${CLUSTER} ${REGION} ${EXEC_ROLE_ARN} ${TASK_ROLE_ARN}' \
  < "$(dirname "$0")/taskdef.json")
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json "$TASK_JSON" \
  --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "  ✓ $TASK_DEF_ARN"

# Create service on first deploy, update on subsequent deploys
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
    --network-configuration "awsvpcConfiguration={subnets=[${PRIVATE_SUBNETS}],securityGroups=[${DATA_SG_ID}],assignPublicIp=ENABLED}" \
    --service-registries "registryArn=${SD_ARN}" \
    --region "$REGION" > /dev/null
  echo "  ✓ Service created: $SERVICE_NAME"
else
  aws ecs update-service \
    --cluster "$CLUSTER" --service "$SERVICE_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --region "$REGION" > /dev/null
  echo "  ✓ Service updated: $SERVICE_NAME"
fi

echo "  DNS: mongodb.roboshop.local:27017"
echo "  Run 'bash scripts/status.sh' to monitor."
