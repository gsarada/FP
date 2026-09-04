#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
MODULE_NAME=${2:-all}
PACKAGE=${3}


echo "🚀 Deploying Financial Planner ${MODULE_NAME} infra to ${ENVIRONMENT}..."

# 1. Build packages if requested
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR=${PROJECT_ROOT}/infra
TF_BACKEND_BUCKET_NAME="fp-app-terraform-state"

PACKAGE_SCRIPT="${SCRIPT_DIR}/package_lambda.sh"

if [[ "${PACKAGE}" == "true" ]]; then
  "${PACKAGE_SCRIPT}" "${MODULE_NAME}" 
fi

# 2. Terraform workspace & apply
cd $INFRA_DIR
if [[ -d temp ]]; then
  rm -r temp
fi
mkdir temp
cp provider.tf temp/
cp modules/$MODULE_NAME/* temp/
key=$MODULE_NAME/terraform.tfstate
echo "${key}"
terraform -chdir=temp init -input=false -backend-config="key=$key"

if ! terraform -chdir=temp workspace list | grep -q "$ENVIRONMENT"; then
  terraform -chdir=temp workspace new "$ENVIRONMENT"
else
  terraform -chdir=temp workspace select "$ENVIRONMENT"
fi

if [[ "${MODULE_NAME}" == "researcher" ]]; then
    # Get ECR repository URL from Terraform
    ecr_url="$(terraform -chdir=temp output --raw ecr_repository_url)"
    echo "ECR repository: ${ecr_url}"

    if [[ "$ecr_url" == "" ]]; then
      
      echo "ECR repository not found, creating..."
      TF_APPLY_CMD=(terraform -chdir=temp apply -var-file="${ENVIRONMENT}.tfvars" 
        -var="backend_bucket_name=${TF_BACKEND_BUCKET_NAME}"
        -target="aws_ecr_repository.researcher" 
        -target="aws_ecr_repository_policy.researcher_lambda_access")
      "${TF_APPLY_CMD[@]}"
    
    fi

    if [[ "${PACKAGE}" == "true" ]]; then

      # Tag image
      docker tag "${MODULE_NAME}:latest" "${ecr_url}:latest"

      # Login to ECR
      aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin "${ecr_url}"

      # Push image
      docker push "${ecr_url}:latest"
    
    fi

    # Apply Terraform with the new image
    TF_APPLY_CMD=(terraform -chdir=temp apply -var-file="${ENVIRONMENT}.tfvars" -var="backend_bucket_name=${TF_BACKEND_BUCKET_NAME}" -var="researcher_image_uri=${ecr_url}:latest")

    "${TF_APPLY_CMD[@]}"
    
else

  # Use env.tfvars for environment
  TF_APPLY_CMD=(terraform -chdir=temp apply -var-file="$ENVIRONMENT.tfvars" -var="backend_bucket_name=${TF_BACKEND_BUCKET_NAME}") #-auto-approve)

  echo "🎯 Applying Terraform..."
  "${TF_APPLY_CMD[@]}"

fi

# 4. Final messages
echo -e "\n✅ $MODULE Deployment complete!"
