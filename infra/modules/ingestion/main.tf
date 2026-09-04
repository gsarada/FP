locals {
  name_prefix = "fp-${var.environment}"

  common_tags = {
    Project     = "fp"
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "ingestion"
  }

  static_endpoints = ["ingest", "search"]
}
# ========================================
# Fetch sagemaker endpoint name from remote state
# ========================================

data "terraform_remote_state" "sagemaker" {
  backend = "s3"

  config = {
    bucket = var.backend_bucket_name
    key    = "env:/${var.environment}/sagemaker/terraform.tfstate"
    region = var.aws_region
  }
}

# ========================================
# S3 Vectors Bucket
# ========================================

resource "random_uuid" "bucket_uuid" {}

resource "aws_s3vectors_vector_bucket" "vectors" {
  vector_bucket_name = "${local.name_prefix}-vectors-bucket"

  encryption_configuration {
    sse_type    = "AES256"
  }
  tags = local.common_tags
}

resource "aws_s3vectors_index" "vector_index" {
  vector_bucket_name = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
  index_name         = "financial-research"
  
  # Configure vector constraints (Forces new resource if changed)
  data_type       = "float32"
  dimension       = 384      # Match for sentence-transformers/all-MiniLM-L6-v2
  distance_metric = "cosine"  # Valid choices: cosine, euclidean
}


# ========================================
# Lambda Function for Ingestion
# ========================================

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-ingest-lambda-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

# Lambda policy for S3 Vectors and SageMaker
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${local.name_prefix}-ingest-lambda-policy"
  role = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3vectors:GetIndex",
          "s3vectors:ListIndexes"
        ]
        Resource = [
          "${aws_s3vectors_vector_bucket.vectors.vector_bucket_arn}",
          "${aws_s3vectors_vector_bucket.vectors.vector_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint"
        ]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${data.terraform_remote_state.sagemaker.outputs.sagemaker_endpoint_name}"
      },
      {
        Effect = "Allow"
        Action = [
          "s3vectors:PutVectors",
          "s3vectors:QueryVectors",
          "s3vectors:GetVectors",
          "s3vectors:DeleteVectors",
          "s3vectors:ListVectors"
        ]
        Resource = "${aws_s3vectors_index.vector_index.index_arn}"
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "ingest" {
  function_name = "${local.name_prefix}-ingest"
  role          = aws_iam_role.lambda_role.arn
  
  filename         = "${path.module}/../../app/ingestion/ingestion_lambda.zip"
  source_code_hash = fileexists("${path.module}/../../app/ingestion/ingestion_lambda.zip") ? filebase64sha256("${path.module}/../../app/ingestion/ingestion_lambda.zip") : null
  
  handler = "lambda_handler.lambda_handler"
  runtime = "python3.12"
  timeout = 60
  memory_size = 512
  
  environment {
    variables = {
      VECTOR_BUCKET      = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
      SAGEMAKER_ENDPOINT = data.terraform_remote_state.sagemaker.outputs.sagemaker_endpoint_name
    }
  }
  
  tags = local.common_tags
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.name_prefix}-ingest"
  retention_in_days = 7
  
  tags = local.common_tags
}

# ========================================
# API Gateway
# ========================================

# REST API
resource "aws_api_gateway_rest_api" "api" {
  name        = "${local.name_prefix}-ingest-api"
  description = "Financial Planner API"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
  
  tags = local.common_tags
}

# API Resource
resource "aws_api_gateway_resource" "endpoints" {
  for_each    = toset(local.static_endpoints)
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = each.value
}

# API Method
resource "aws_api_gateway_method" "post_methods" {
  for_each      = aws_api_gateway_resource.endpoints
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = each.value.id
  http_method   = "POST"
  authorization = "NONE"
  api_key_required = true
}

# Lambda Integration
resource "aws_api_gateway_integration" "lambda" {
  for_each    = aws_api_gateway_method.post_methods
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = each.value.resource_id
  http_method = each.value.http_method
  
  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.ingest.invoke_arn
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# API Deployment
resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.endpoints,
      aws_api_gateway_method.post_methods,
      aws_api_gateway_integration.lambda,
    ]))
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# API Stage
resource "aws_api_gateway_stage" "api" {
  deployment_id = aws_api_gateway_deployment.api.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "prod"
  
  tags = local.common_tags
}

# API Key
resource "aws_api_gateway_api_key" "api_key" {
  name = "${local.name_prefix}-ingest-api-key"
  
  tags = local.common_tags
}

# Usage Plan
resource "aws_api_gateway_usage_plan" "plan" {
  name = "${local.name_prefix}-usage-plan"
  
  api_stages {
    api_id = aws_api_gateway_rest_api.api.id
    stage  = aws_api_gateway_stage.api.stage_name
  }
  
  quota_settings {
    limit  = 5000
    period = "MONTH"
  }
  
  throttle_settings {
    rate_limit  = 100
    burst_limit = 200
  }
}

# Usage Plan Key
resource "aws_api_gateway_usage_plan_key" "plan_key" {
  key_id        = aws_api_gateway_api_key.api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.plan.id
}