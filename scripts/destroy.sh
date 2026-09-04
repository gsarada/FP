#!/bin/bash
set -e

# Check if environment parameter is provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Environment parameter is required"
    echo "Usage: $0 <environment>"
    echo "Example: $0 dev"
    echo "Available environments: dev, test, prod"
    exit 1
fi

ENVIRONMENT=$1
MODULE_NAME=${2:-all}

echo "🗑️ Preparing to destroy Financial Planner ${MODULE_NAME}-${ENVIRONMENT} infrastructure..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR=${PROJECT_ROOT}/infra

# Navigate to terraform directory
cd "${INFRA_DIR}"
if [[ -d temp ]]; then
  rm -r temp
fi
mkdir temp
cp provider.tf temp/
cp modules/$MODULE_NAME/* temp/
key=$MODULE_NAME/terraform.tfstate
echo "${key}"
terraform -chdir=temp init -input=false -backend-config="key=$key"

# Check if workspace exists
if ! terraform -chdir=temp workspace list | grep -q "$ENVIRONMENT"; then
    echo "❌ Error: Workspace '$ENVIRONMENT' does not exist"
    echo "Available workspaces:"
    terraform -chdir=temp workspace list
    exit 1
fi

# Select the workspace
terraform -chdir=temp workspace select "$ENVIRONMENT"

echo "📦 Emptying S3 buckets..."

# Get bucket names from state outputs if any
buckets=$(terraform -chdir=temp output -json | jq -r 'to_entries[] | select(.key | contains("bucket")) | .value.value')
echo "Buckets - ${buckets}"

# Empty buckets if any exists
if $buckets and aws s3 ls "s3://$buckets[0]" 2>/dev/null; then
    echo "  Emptying $buckets[0]..."
    aws s3 rm "s3://$buckets[0]" --recursive
else
    echo "  Bucket not found or already empty"
fi

echo "🔥 Running terraform destroy..."

# Run terraform destroy with auto-approve
terraform -chdir=temp destroy -var-file="$ENVIRONMENT.tfvars" -var="environment=$ENVIRONMENT" -var="backend_bucket_name=fp-app-terraform-state" #-auto-approve


rm -rf temp
echo "✅ Infrastructure for ${MODULE_NAME}-${ENVIRONMENT} has been destroyed!"
echo ""
echo "💡 To remove the workspace completely, run:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"
echo "   run this with caution only when you intend to clean the entire infrastructure state within an environment"