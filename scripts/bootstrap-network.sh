#!/bin/bash
# Store VPC / subnet IDs in SSM Parameter Store before running 00-setup/setup.sh
#
# Usage:
#   bash scripts/bootstrap-network.sh <env> <vpc_id> <private_subnets> <public_subnets>
#
# Example:
#   bash scripts/bootstrap-network.sh dev vpc-0abc123 "subnet-aaa,subnet-bbb" "subnet-ccc,subnet-ddd"

set -euo pipefail

ENV=${1:?  "Usage: $0 <env> <vpc_id> <private_subnet_ids> <public_subnet_ids>"}
VPC_ID=${2:? "Usage: $0 <env> <vpc_id> <private_subnet_ids> <public_subnet_ids>"}
PRIVATE=${3:?"Usage: $0 <env> <vpc_id> <private_subnet_ids> <public_subnet_ids>"}
PUBLIC=${4:? "Usage: $0 <env> <vpc_id> <private_subnet_ids> <public_subnet_ids>"}
REGION=${AWS_REGION:-us-east-1}

echo "Storing network config for environment: $ENV"

aws ssm put-parameter \
  --name "/network/${ENV}/vpc_id" \
  --value "$VPC_ID" \
  --type String \
  --overwrite \
  --region "$REGION"
echo "  ✓ /network/${ENV}/vpc_id = $VPC_ID"

aws ssm put-parameter \
  --name "/network/${ENV}/private_subnet_ids" \
  --value "$PRIVATE" \
  --type String \
  --overwrite \
  --region "$REGION"
echo "  ✓ /network/${ENV}/private_subnet_ids = $PRIVATE"

aws ssm put-parameter \
  --name "/network/${ENV}/public_subnet_ids" \
  --value "$PUBLIC" \
  --type String \
  --overwrite \
  --region "$REGION"
echo "  ✓ /network/${ENV}/public_subnet_ids = $PUBLIC"

echo ""
echo "Done. Run 'bash 00-setup/setup.sh' next."
