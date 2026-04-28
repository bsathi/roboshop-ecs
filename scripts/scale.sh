#!/bin/bash
# Scale a specific Roboshop service up or down
# Equivalent to: docker compose up -d --scale catalogue=3
#
# Usage: ENV=dev bash scripts/scale.sh <component> <count>
#
# Examples:
#   bash scripts/scale.sh catalogue 3    # scale out
#   bash scripts/scale.sh catalogue 1    # scale back
#   bash scripts/scale.sh catalogue 0    # stop (zero cost)

set -euo pipefail

ENV=${ENV:-dev}
PROJECT=${PROJECT:-roboshop}
REGION=${AWS_REGION:-us-east-1}
COMPONENT=${1:?"Usage: $0 <component> <count>"}
COUNT=${2:?"Usage: $0 <component> <count>"}
CLUSTER="${PROJECT}-${ENV}"
SERVICE="${CLUSTER}-${COMPONENT}"

echo "Scaling  ${SERVICE}  →  desired count: ${COUNT}"

aws ecs update-service \
  --cluster  "$CLUSTER" \
  --service  "$SERVICE" \
  --desired-count "$COUNT" \
  --region   "$REGION" \
  --query    'service.{Service:serviceName,Desired:desiredCount,Running:runningCount}' \
  --output   table

echo ""
echo "Run 'bash scripts/status.sh' to monitor rollout."
