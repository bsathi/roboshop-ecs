#!/bin/bash
# Show running / desired task counts for all Roboshop ECS services
#
# Usage: ENV=dev bash scripts/status.sh

set -euo pipefail

ENV=${ENV:-dev}
PROJECT=${PROJECT:-roboshop}
REGION=${AWS_REGION:-us-east-1}
CLUSTER="${PROJECT}-${ENV}"

echo "=== Roboshop ECS Fargate — ${CLUSTER} ==="
echo ""

SERVICES=(
  "${CLUSTER}-mongodb"
  "${CLUSTER}-redis"
  "${CLUSTER}-mysql"
  "${CLUSTER}-rabbitmq"
  "${CLUSTER}-catalogue"
  "${CLUSTER}-cart"
  "${CLUSTER}-user"
  "${CLUSTER}-payment"
  "${CLUSTER}-shipping"
  "${CLUSTER}-frontend"
)

aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "${SERVICES[@]}" \
  --region "$REGION" \
  --query 'services[*].{
    Service:serviceName,
    Status:status,
    Desired:desiredCount,
    Running:runningCount,
    Pending:pendingCount
  }' \
  --output table

# Show application URL
ALB_DNS=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/alb_dns" \
  --query Parameter.Value --output text \
  --region "$REGION" 2>/dev/null || echo "not deployed")

echo ""
echo "Application URL : http://${ALB_DNS}"
echo ""
echo "Tail logs:"
echo "  aws logs tail /ecs/${CLUSTER}/catalogue --follow --region ${REGION}"
echo "  aws logs tail /ecs/${CLUSTER}/cart      --follow --region ${REGION}"
echo "  aws logs tail /ecs/${CLUSTER}/frontend  --follow --region ${REGION}"
