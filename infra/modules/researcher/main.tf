locals {
  researcher_deployed = var.researcher_image_uri != ""
  scheduler_active    = var.scheduler_enabled && local.researcher_deployed
  name_prefix = "fp-${var.environment}"

  common_tags = {
    Project     = "fp"
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "researcher"
  }
}

data "terraform_remote_state" "ingestion" {
  backend = "s3"

  config = {
    bucket = var.backend_bucket_name
    key    = "env:/${var.environment}/ingestion/terraform.tfstate"
    region = var.aws_region
  }
}

# ECR repository for the researcher Docker image
resource "aws_ecr_repository" "researcher" {
  name                 = "${local.name_prefix}-researcher-ecr"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = local.common_tags
}

# Allow Lambda to pull images from ECR
resource "aws_ecr_repository_policy" "researcher_lambda_access" {
  repository = aws_ecr_repository.researcher.name

  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [
      {
        Sid    = "LambdaEcrImageRetrievalPolicy"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Condition = {
          ArnLike = {
            "aws:sourceArn" = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:*"
          }
        }
      }
    ]
  })
}

# IAM role for researcher Lambda
resource "aws_iam_role" "researcher_lambda_role" {
  name = "${local.name_prefix}-researcher-lambda-role"

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

# Lambda basic execution policy
resource "aws_iam_role_policy_attachment" "researcher_lambda_basic" {
  role       = aws_iam_role.researcher_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Policy for researcher Lambda to access Bedrock
resource "aws_iam_role_policy" "researcher_lambda_bedrock_access" {
  name = "${local.name_prefix}-researcher-lambda-bedrock-policy"
  role = aws_iam_role.researcher_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListFoundationModels"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "apigateway:GET"
        ]
        Resource = "*"
      }
    ]
  })
}

# Researcher Lambda function
resource "aws_lambda_function" "researcher" {
  count         = local.researcher_deployed ? 1 : 0
  function_name = "${local.name_prefix}-researcher"
  package_type  = "Image"
  image_uri     = var.researcher_image_uri
  role          = aws_iam_role.researcher_lambda_role.arn
  timeout       = 300
  memory_size   = 2048
  architectures = ["x86_64"]

  ephemeral_storage {
    size = 2048
  }

  environment {
    variables = {
      INGEST_API_ENDPOINT = "${data.terraform_remote_state.ingestion.outputs.api_endpoint}"
      INGEST_API_KEY      = "${data.terraform_remote_state.ingestion.outputs.api_key_id}"
      BEDROCK_REGION    = var.bedrock_region
      RESEARCHER_MODEL  = var.researcher_model
      MCP_LOGGING       = var.mcp_logging
    }
  }

  tags = local.common_tags
}

# Public function URL for the researcher service
resource "aws_lambda_function_url" "researcher" {
  count              = local.researcher_deployed ? 1 : 0
  function_name      = aws_lambda_function.researcher[0].function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "allow_public_function_url_invoke" {
  count                    = local.researcher_deployed ? 1 : 0
  statement_id             = "AllowPublicFunctionInvokeViaUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.researcher[0].function_name
  principal                = "*"
  invoked_via_function_url = true
}

# IAM role for EventBridge
resource "aws_iam_role" "eventbridge_role" {
  count = local.scheduler_active ? 1 : 0
  name  = "${local.name_prefix}-eventbridge-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# EventBridge schedule
resource "aws_scheduler_schedule" "research_schedule" {
  count = local.scheduler_active ? 1 : 0
  name  = "${local.name_prefix}-research-schedule"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(5 minutes)"

  target {
    arn      = aws_lambda_function.researcher[0].arn
    role_arn = aws_iam_role.eventbridge_role[0].arn

    input = jsonencode({
      version  = "2.0"
      routeKey = "GET /research/auto"
      rawPath  = "/research/auto"
      requestContext = {
        http = {
          method = "GET"
          path   = "/research/auto"
        }
      }
      isBase64Encoded = false
    })
  }
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  count         = local.scheduler_active ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.researcher[0].function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.research_schedule[0].arn
}

# Policy for EventBridge to invoke Lambda
resource "aws_iam_role_policy" "eventbridge_invoke_lambda" {
  count = local.scheduler_active ? 1 : 0
  name  = "InvokeLambdaPolicy"
  role  = aws_iam_role.eventbridge_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.researcher[0].arn
      }
    ]
  })
}
