#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Arguments
###############################################################################

ENVIRONMENT="${1:-dev}"       # dev | test | prod
MODULE_NAME="${2:-all}"       # ingestion | researcher | agents | frontend | all
ACTION="${3:-all}"            # package | infra-deploy | app-deploy | all

###############################################################################
# Paths / configuration
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${PROJECT_ROOT}/infra"

PACKAGE_SCRIPT="${SCRIPT_DIR}/package.sh"
APP_DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy_app.sh"

TF_BACKEND_BUCKET_NAME="fp-app-terraform-state"
AWS_REGION="ap-southeast-1"

###############################################################################
# Validation
###############################################################################

VALID_ACTIONS=("package" "infra-deploy" "app-deploy" "all")
VALID_MODULES=("sagemaker" "ingestion" "researcher" "database" "agents" "frontend" "dashboard" "all")

if [[ ! " ${VALID_ACTIONS[*]} " =~ " ${ACTION} " ]]; then
    echo "ERROR: Invalid action '${ACTION}'"
    echo "Valid actions: ${VALID_ACTIONS[*]}"
    exit 1
fi

if [[ ! " ${VALID_MODULES[*]} " =~ " ${MODULE_NAME} " ]]; then
    echo "ERROR: Invalid module '${MODULE_NAME}'"
    echo "Valid modules: ${VALID_MODULES[*]}"
    exit 1
fi

echo "=========================================="
echo "Financial Planner Deployment"
echo "=========================================="
echo "Environment : ${ENVIRONMENT}"
echo "Module      : ${MODULE_NAME}"
echo "Action      : ${ACTION}"
echo "=========================================="

###############################################################################
# Helpers
###############################################################################

should_run_package() {
    [[ "${ACTION}" == "package" || "${ACTION}" == "all" ]]
}

should_run_infra() {
    [[ "${ACTION}" == "infra-deploy" || "${ACTION}" == "all" ]]
}

should_run_app() {
    [[ "${ACTION}" == "app-deploy" || "${ACTION}" == "all" ]]
}

###############################################################################
# Package
###############################################################################

if should_run_package; then

    echo "========== PACKAGE =========="

    if [[ "${MODULE_NAME}" == "all" ]]; then
        for module in ingestion researcher agents api frontend; do
            "${PACKAGE_SCRIPT}" "${module}"
        done
    elif [[ "${MODULE_NAME}" == "frontend" ]]; then
        for module in api frontend; do
            "${PACKAGE_SCRIPT}" "${module}"
        done
    else
        "${PACKAGE_SCRIPT}" "${MODULE_NAME}"
    fi

fi

###############################################################################
# Terraform preparation
###############################################################################

prepare_terraform() {

    echo
    echo "========== TERRAFORM PREPARATION =========="

    local module_name="$1"
    cd "${INFRA_DIR}"

    rm -rf temp
    mkdir -p temp

    cp provider.tf temp/

    cp "modules/${module_name}"/* temp/

    local key="${module_name}/terraform.tfstate"

    echo "Terraform state key: ${key}"

    terraform -chdir=temp init \
        -input=false \
        -backend-config="key=${key}"

    if ! terraform -chdir=temp workspace list | grep -Eq "^[*[:space:]]+${ENVIRONMENT}$"; then
        terraform -chdir=temp workspace new "${ENVIRONMENT}"
    else
        terraform -chdir=temp workspace select "${ENVIRONMENT}"
    fi
}

###############################################################################
# Researcher ECR handling
###############################################################################

ensure_researcher_ecr() {

    local ecr_url

    echo
    echo "========== RESEARCHER ECR =========="

    ecr_url="$(
        terraform -chdir=temp output --raw ecr_repository_url 2>/dev/null || true
    )"

    if [[ -n "${ecr_url}" ]]; then
        echo "ECR repository already exists:"
        echo "${ecr_url}"
        return 0
    fi

    echo "ECR repository not found."
    echo "Creating ECR repository first..."

    terraform -chdir=temp apply \
        -var-file="${ENVIRONMENT}.tfvars" \
        -var="backend_bucket_name=${TF_BACKEND_BUCKET_NAME}" \
        -target="aws_ecr_repository.researcher" \
        -target="aws_ecr_repository_policy.researcher_lambda_access" \
        -auto-approve

}

push_researcher_image() {

    local ecr_url="$1"

    if [[ -z "${ecr_url}" ]]; then
        echo "ERROR: ECR repository URL not available."
        exit 1
    fi

    echo
    echo "========== PUSH RESEARCHER IMAGE =========="

    echo "Tagging image..."

    docker tag "researcher:latest" "${ecr_url}:latest"

    echo "Logging into ECR..."

    aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ecr_url}"

    echo "Pushing image..."

    docker push "${ecr_url}:latest"

    echo "Researcher image pushed successfully."
}

###############################################################################
# Terraform deployment
###############################################################################

deploy_infrastructure() {
    local module_name="$1"

    echo "========== DEPLOYING INFRA - ${module_name} =========="
    prepare_terraform "${module_name}"

    local terraform_args=(
        "apply"
        "-var-file=${ENVIRONMENT}.tfvars"
        "-var=backend_bucket_name=${TF_BACKEND_BUCKET_NAME}"
        "-auto-approve"
    )

    if [[ "${module_name}" == "researcher" ]]; then
        local ecr_url

        ensure_researcher_ecr

        ecr_url="$(
            terraform -chdir=temp output --raw ecr_repository_url
        )"

        push_researcher_image "${ecr_url}"

        if should_run_package; then
            push_researcher_image "${ecr_url}"
        fi

        terraform_args+=(
            "-var=researcher_image_uri=${ecr_url}:latest"
        )
    fi

    echo
    echo "========== INFRA DEPLOY =========="

    terraform -chdir=temp "${terraform_args[@]}"
}

###############################################################################
# Main deployment flow
###############################################################################

if should_run_infra; then
    if [[ "${MODULE_NAME}" == "all" ]]; then
        
        for module in sagemaker ingestion researcher database agents frontend dashboard; do
            
            deploy_infrastructure "${module}"
        
        done
    
    else

        deploy_infrastructure "${MODULE_NAME}"

    fi
fi

###############################################################################
# Application deployment
###############################################################################

if should_run_app; then

    echo
    echo "========== APP DEPLOY =========="

    "${APP_DEPLOY_SCRIPT}" "${ENVIRONMENT}" "${MODULE_NAME}"

fi

###############################################################################
# Complete
###############################################################################

echo
echo "=========================================="
echo "Deployment complete"
echo "Environment : ${ENVIRONMENT}"
echo "Module      : ${MODULE_NAME}"
echo "Action      : ${ACTION}"
echo "=========================================="