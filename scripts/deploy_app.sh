#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="${1:-}"
MODULE="${2:-}"

if [[ -z "${ENVIRONMENT}" || -z "${MODULE}" ]]; then
    echo "Usage: $0 <environment> <module>"
    exit 1
fi

###############################################################################
# Frontend
###############################################################################

deploy_frontend_app() {

    local bucket_name="$1"
    local cloudfront_id="$2"
    local cloudfront_url="$3"

    local frontend_dir="${PROJECT_ROOT}/app/frontend"
    local out_dir="${frontend_dir}/out"
    local env_local="${frontend_dir}/.env.local"
    local env_prod="${out_dir}/.env.production.local"

    # 1. Ensure the destination directory exists before creating the file
    mkdir -p "${out_dir}"

    # Create production env from .env.local
    sed "s|^NEXT_PUBLIC_API_URL=.*|NEXT_PUBLIC_API_URL=${cloudfront_url}|" \
        "${env_local}" > "${env_prod}"
    
    # Add variable if it doesn't already exist
    grep -q "^NEXT_PUBLIC_API_URL=" "${env_prod}" || \
        echo "NEXT_PUBLIC_API_URL=${cloudfront_url}" >> "${env_prod}"

    cat "${env_prod}"

    echo "Building NextJS application..."

    NODE_ENV=production npm run build --prefix "${frontend_dir}"

    [[ -d "${out_dir}" ]] || {
        echo "ERROR: Frontend build output not found: ${out_dir}"
        exit 1
    }

    echo "Frontend build completed."

    [[ -n "${bucket_name}" ]] || {
        echo "ERROR: S3 bucket name is required."
        exit 1
    }

    [[ -n "${cloudfront_id}" ]] || {
        echo "ERROR: CloudFront ID is required."
        exit 1
    }

    echo "=========================================="
    echo "Deploying frontend"
    echo "=========================================="

    echo "Uploading frontend..."

    # --delete makes the explicit `aws s3 rm` unnecessary.
    aws s3 sync \
        "${out_dir}/" \
        "s3://${bucket_name}/" \
        --delete \
        --cache-control "max-age=31536000,public"

    # HTML should not be aggressively cached.
    aws s3 sync \
        "${out_dir}/" \
        "s3://${bucket_name}/" \
        --exclude "*" \
        --include "*.html" \
        --cache-control "max-age=0,no-cache,no-store,must-revalidate" \
        --content-type "text/html"

    echo "Invalidating CloudFront cache..."

    aws cloudfront create-invalidation \
        --distribution-id "${cloudfront_id}" \
        --paths "/*" > /dev/null

    echo "Frontend deployed successfully."

}

###############################################################################
# Lambda deployment
###############################################################################

deploy_lambda_app() {

    local app="$1"
    local function_name="$2"

    local zip_file="${PROJECT_ROOT}/app/${app}/${app}_lambda.zip"

    [[ -f "${zip_file}" ]] || {
        echo "ERROR: Lambda package not found: ${zip_file}"
        exit 1
    }

    echo
    echo "Deploying Lambda: ${function_name}"

    aws lambda update-function-code \
        --function-name "${function_name}" \
        --zip-file "fileb://${zip_file}" > /dev/null

    echo "Lambda deployed successfully."

}

###############################################################################
# Agent Lambdas
###############################################################################

deploy_agent_lambdas() {

    # Replace these with your actual Terraform outputs.
    local lambda_functions="$1"

    for entry in "${lambda_functions[@]}"; do

        local agent_name="${entry%%|*}"
        local function_name="${entry#*|}"

        echo "Deploying ${agent_name} → ${function_name}"
        deploy_lambda_app "agents/${agent_name}" "${function_name}"
    done
}

###############################################################################
# Module dispatch
###############################################################################

INFRA_DIR="${PROJECT_ROOT}/infra"
TF_DIR="${INFRA_DIR}/temp"

case "${MODULE}" in

    frontend)

        bucket_name="$(
            terraform -chdir="${TF_DIR}" output --raw s3_bucket_name
        )"

        cloudfront_id="$(
            terraform -chdir="${TF_DIR}" output --raw cloudfront_id
        )"

        cloudfront_url="$(
            terraform -chdir="${TF_DIR}" output --raw cloudfront_url
        )"

        function_name="$(
            terraform -chdir="${TF_DIR}" output --raw lambda_function_name
        )"

        deploy_frontend_app "${bucket_name}" "${cloudfront_id}" "${cloudfront_url}"

        deploy_lambda_app "api" "${function_name}"
        ;;

    agents)
        
        mapfile -t lambda_functions < <(
            terraform -chdir="${TF_DIR}" output -json lambda_functions |
            jq -r 'to_entries[] | "\(.key)|\(.value)"'
        )
        
        deploy_agent_lambdas "${lambda_functions[@]}"
        ;;

    ingestion)

        function_name="$(
            terraform -chdir="${TF_DIR}" output --raw lambda_function_name
        )"

        deploy_lambda_app "ingestion" "${function_name}"
        ;;

    researcher)

        echo "Researcher application deployment is handled through ECR."
        echo "The researcher image is pushed during the main deployment flow."
        ;;

    *)

        echo "ERROR: Unsupported application module '${MODULE}'."
        exit 0
        ;;

esac