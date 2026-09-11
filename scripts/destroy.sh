#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Usage
# ------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "❌ Environment parameter is required"
    echo "Usage: $0 <environment> [module]"
    echo "Example: $0 dev"
    echo "Example: $0 dev agents"
    echo "Example: $0 dev all"
    echo
    echo "Available environments: dev, test, prod"
    exit 1
fi

ENVIRONMENT="$1"
MODULE_NAME="${2:-all}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${PROJECT_ROOT}/infra"
TEMP_DIR="${INFRA_DIR}/temp"

BACKEND_BUCKET="fp-app-terraform-state"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
all=(dashboard frontend agents database researcher ingestion sagemaker)


# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

validate_module() {
    local module="$1"

    if [[ "$module" == "all" ]]; then
        return 0
    fi

    if [[ ! -d "${INFRA_DIR}/modules/${module}" ]]; then
        echo "❌ Unknown module: ${module}"
        echo
        echo "Available modules:"
        find "${INFRA_DIR}/modules" -mindepth 1 -maxdepth 1 -type d \
            -exec basename {} \; | sort
        exit 1
    fi
}

prepare_terraform() {
    local module="$1"

    echo
    echo "📦 Preparing Terraform for module: ${module}"

    rm -rf "${TEMP_DIR}"
    mkdir -p "${TEMP_DIR}"

    cp "${INFRA_DIR}/provider.tf" "${TEMP_DIR}/"

    # Copy module Terraform configuration
    cp "${INFRA_DIR}/modules/${module}"/* "${TEMP_DIR}/"

    terraform -chdir="${TEMP_DIR}" init -input=false -backend-config="key=${module}/terraform.tfstate"
}

select_workspace() {
    echo "🔍 Checking Terraform workspace: ${ENVIRONMENT}"

    if ! terraform -chdir="${TEMP_DIR}" workspace list \
        | sed 's/^[* ]*//' \
        | grep -Fxq "${ENVIRONMENT}"; then

        echo "❌ Workspace '${ENVIRONMENT}' does not exist"
        echo
        echo "Available workspaces:"
        terraform -chdir="${TEMP_DIR}" workspace list
        exit 1
    fi

    terraform -chdir="${TEMP_DIR}" workspace select "${ENVIRONMENT}"
}

empty_buckets() {
    echo
    echo "🗑️ Checking S3 buckets..."

    local buckets=()

    # Get bucket names from state outputs if any
    # 1. Capture the raw text output into a standard variable
    raw_output=$(terraform -chdir="${TEMP_DIR}" output -json | jq -r 'to_entries[] | select(.key | endswith("-bucket")) | .value.value')

    echo "${raw_output}"
    # 2. Split the text into the Zsh array by newlines
    buckets=("${raw_output}")

    echo "Buckets - ${buckets}"

    if [[ ${#buckets[@]} -eq 0 ]]; then
        echo "  No S3 buckets found."
        return
    fi

    for bucket in "${buckets[@]}"; do
        [[ -z "${bucket}" || "${bucket}" == "null" ]] && continue

        if aws s3 ls "s3://${bucket}" >/dev/null 2>&1; then
            echo "  Emptying: ${bucket}"
            aws s3 rm "s3://${bucket}" --recursive
        else
            echo "  ⚠️ Bucket not found/inaccessible: ${bucket}"
        fi
    done
}

destroy_module() {
    local module="$1"

    echo
    echo "============================================================"
    echo "🔥 Destroying ${module}-${ENVIRONMENT}"
    echo "============================================================"

    prepare_terraform "${module}"
    select_workspace
    empty_buckets

    echo
    echo "🔥 Running Terraform destroy..."

    terraform -chdir="${TEMP_DIR}" destroy \
        -var-file="${ENVIRONMENT}.tfvars" \
        -var="backend_bucket_name=${BACKEND_BUCKET}" \
        -auto-approve

    echo "✅ ${module}-${ENVIRONMENT} destroyed successfully"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

validate_module "${MODULE_NAME}"

echo
echo "🗑️ Preparing to destroy:"
echo "   Environment : ${ENVIRONMENT}"
echo "   Module      : ${MODULE_NAME}"
echo

if [[ "${MODULE_NAME}" == "all" ]]; then

    for module in ${all[@]]}; do
        destroy_module "${module}"
    done

else
    destroy_module "${MODULE_NAME}"
fi

echo
echo "============================================================"
echo "✅ Infrastructure destruction completed"
echo "   Environment : ${ENVIRONMENT}"
echo "   Module      : ${MODULE_NAME}"
echo "============================================================"
echo
echo "💡 Terraform workspace '${ENVIRONMENT}' was NOT deleted."
echo "   To remove it:"
echo
echo "   terraform workspace select default"
echo "   terraform workspace delete ${ENVIRONMENT}"