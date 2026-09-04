#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod

echo "🚀 Getting Financial Planner ${ENVIRONMENT} infra outputs ..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR=${PROJECT_ROOT}/infra
TF_BACKEND_BUCKET_NAME="fp-app-terraform-state"
MODULES=("agents" "database" "ingestion" "researcher" "sagemaker")

# 2. Terraform workspace & apply
cd $INFRA_DIR

for MODULE_NAME in ${MODULES[@]}; do
 
  rm -r temp
  mkdir temp
  cp provider.tf temp/
  key=$MODULE_NAME/terraform.tfstate
  echo "${key}"
  terraform -chdir=temp init -input=false -backend-config="key=$key"

  if ! terraform -chdir=temp workspace list | grep -q "$ENVIRONMENT"; then
    echo "Workspace ${ENVIRONMENT} not found"
    exit 1
  else
    terraform -chdir=temp workspace select "$ENVIRONMENT"
  fi

  echo "------------------------------------------"
  echo " Terraform outputs of module ${MODULE_NAME} "
  echo "------------------------------------------"

  TF_CMD=(terraform -chdir=temp output) #-auto-approve)

  echo "🎯 Applying Terraform..."
  "${TF_CMD[@]}"

done

# 4. Final messages
echo -e "\n✅ Outputs retrieved successfully!"
