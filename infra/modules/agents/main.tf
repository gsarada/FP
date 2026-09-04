locals {
  name_prefix = "fp-${var.environment}"

  common_tags = {
    Project     = "fp"
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "agents"
  }
}

# ========================================
# SQS Queue for Async Job Processing
# ========================================

resource "aws_sqs_queue" "analysis_jobs" {
  name                       = "${local.name_prefix}-analysis-jobs"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400  # 1 day
  receive_wait_time_seconds = 10     # Long polling
  visibility_timeout_seconds = 910   # 15 minutes + 10 seconds buffer (matches Planner Lambda timeout)
  
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.analysis_jobs_dlq.arn
    maxReceiveCount     = 3
  })
  
  tags = local.common_tags
}

resource "aws_sqs_queue" "analysis_jobs_dlq" {
  name = "${local.name_prefix}-analysis-jobs-dlq"
  
  tags = local.common_tags
}

# ========================================
# IAM Role for Lambda Functions
# ========================================

resource "aws_iam_role" "lambda_agents_role" {
  name = "${local.name_prefix}-lambda-agents-role"

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

# IAM policy for Lambda agents
resource "aws_iam_role_policy" "lambda_agents_policy" {
  name = "${local.name_prefix}-lambda-agents-policy"
  role = aws_iam_role.lambda_agents_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      # SQS access for orchestrator
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.analysis_jobs.arn
      },
      # Lambda invocation for orchestrator to call other agents
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:fp-*"
      },
      # Aurora Data API access
      {
        Effect = "Allow"
        Action = [
          "rds-data:ExecuteStatement",
          "rds-data:BatchExecuteStatement",
          "rds-data:BeginTransaction",
          "rds-data:CommitTransaction",
          "rds-data:RollbackTransaction"
        ]
        Resource = "${data.terraform_remote_state.db.outputs.aurora_cluster_arn}"
      },
      # Secrets Manager for database credentials
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          "${data.terraform_remote_state.db.outputs.aurora_secret_arn}"
        ]
      },
      # S3 Vectors access for all agents
      {
        Effect = "Allow"
        Action = [
          "s3vectors:GetIndex",
          "s3vectors:ListIndexes"
        ]
        Resource = [
          "arn:aws:s3vectors:${var.aws_region}:${data.aws_caller_identity.current.account_id}:bucket/${data.terraform_remote_state.ingestion.outputs.vector_bucket_name}",
          "arn:aws:s3vectors:${var.aws_region}:${data.aws_caller_identity.current.account_id}:bucket/${data.terraform_remote_state.ingestion.outputs.vector_bucket_name}/*"
        ]
      },
      # S3 Vectors API access for all agents
      {
        Effect = "Allow"
        Action = [
          "s3vectors:QueryVectors",
          "s3vectors:GetVectors",
          "s3vectors:ListVectors"
        ]
        Resource = "arn:aws:s3vectors:${var.aws_region}:${data.aws_caller_identity.current.account_id}:bucket/${data.terraform_remote_state.ingestion.outputs.vector_bucket_name}/index/*"
      },
      # SageMaker endpoint access for reporter agent
      {
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint"
        ]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${data.terraform_remote_state.sagemaker.outputs.sagemaker_endpoint_name}"
      },
      # Bedrock access for all agents
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        # Replaced ${var.bedrock_region} with * for Bedrock region workaround
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:*:inference-profile/*"
        ]
      }
    ]
  })
}

# Attach basic Lambda execution role
resource "aws_iam_role_policy_attachment" "lambda_agents_basic" {
  role       = aws_iam_role.lambda_agents_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ========================================
# S3 Bucket for Lambda Deployments
# ========================================

# S3 bucket for Lambda packages (packages > 50MB must use S3)
resource "aws_s3_bucket" "lambda_packages" {
  bucket = "${local.name_prefix}-lambda-packages-bucket"
  
  tags = local.common_tags
}

# Upload Lambda packages to S3
resource "aws_s3_object" "lambda_packages" {
  for_each = toset(["planner", "tagger", "reporter", "charter", "retirement"])
  
  bucket = aws_s3_bucket.lambda_packages.id
  key    = "${each.key}/${each.key}_lambda.zip"
  source = "${path.module}/../../app/agents/${each.key}/${each.key}_lambda.zip"
  etag   = fileexists("${path.module}/../../app/agents/${each.key}/${each.key}_lambda.zip") ? filemd5("${path.module}/../../app/agents/${each.key}/${each.key}_lambda.zip") : null
  
  tags = merge(
    local.common_tags,
    {
      Agent   = each.key
    }
  )
}

# ========================================
# Lambda Functions for Each Agent
# ========================================

# Planner (Orchestrator) Lambda
resource "aws_lambda_function" "planner" {
  function_name = "${local.name_prefix}-planner"
  role          = aws_iam_role.lambda_agents_role.arn
  
  # Using S3 for deployment package (>50MB)
  s3_bucket        = aws_s3_bucket.lambda_packages.id
  s3_key           = aws_s3_object.lambda_packages["planner"].key
  source_code_hash = fileexists("${path.module}/../../app/agents/planner/planner_lambda.zip") ? filebase64sha256("${path.module}/../../app/agents/planner/planner_lambda.zip") : null
  
  handler     = "lambda_handler.lambda_handler"
  runtime     = "python3.12"
  timeout     = 900  # 15 minutes for planner
  memory_size = 2048  # 2GB for planner
  
  environment {
    variables = {
      AURORA_CLUSTER_ARN = "${data.terraform_remote_state.db.outputs.aurora_cluster_arn}"
      AURORA_SECRET_ARN  = "${data.terraform_remote_state.db.outputs.aurora_secret_arn}"
      DATABASE_NAME      = "fp"
      VECTOR_BUCKET      = "${data.terraform_remote_state.ingestion.outputs.vector_bucket_name}"
      BEDROCK_MODEL_ID   = var.bedrock_model_id
      BEDROCK_REGION     = var.bedrock_region
      DEFAULT_AWS_REGION = var.aws_region
      SAGEMAKER_ENDPOINT = "${data.terraform_remote_state.sagemaker.outputs.sagemaker_endpoint_name}"
      POLYGON_API_KEY    = var.polygon_api_key
      POLYGON_PLAN       = var.polygon_plan
      # LangFuse observability (optional)
      LANGFUSE_PUBLIC_KEY = var.langfuse_public_key
      LANGFUSE_SECRET_KEY = var.langfuse_secret_key
      LANGFUSE_HOST       = var.langfuse_host
      OPENAI_API_KEY      = var.openai_api_key
      ENV                 = var.environment
    }
  }

  tags = merge(
    local.common_tags,
    {
      Agent   = "orchestrator"
    }
  )
  
  depends_on = [aws_s3_object.lambda_packages["planner"]]
}

# SQS trigger for Planner
resource "aws_lambda_event_source_mapping" "planner_sqs" {
  event_source_arn = aws_sqs_queue.analysis_jobs.arn
  function_name    = aws_lambda_function.planner.arn
  batch_size       = 1
}

# Tagger Lambda
resource "aws_lambda_function" "tagger" {
  function_name = "${local.name_prefix}-tagger"
  role          = aws_iam_role.lambda_agents_role.arn

  # Using S3 for deployment package (>50MB)
  s3_bucket        = aws_s3_bucket.lambda_packages.id
  s3_key           = aws_s3_object.lambda_packages["tagger"].key
  source_code_hash = fileexists("${path.module}/../../app/agents/tagger/tagger_lambda.zip") ? filebase64sha256("${path.module}/../../app/agents/tagger/tagger_lambda.zip") : null

  handler     = "lambda_handler.lambda_handler"
  runtime     = "python3.12"
  timeout     = 300  # 5 minutes for tagger
  memory_size = 1024

  environment {
    variables = {
      AURORA_CLUSTER_ARN = "${data.terraform_remote_state.db.outputs.aurora_cluster_arn}"
      AURORA_SECRET_ARN  = "${data.terraform_remote_state.db.outputs.aurora_secret_arn}"
      DATABASE_NAME      = "fp"
      BEDROCK_MODEL_ID   = var.bedrock_model_id
      BEDROCK_REGION     = var.bedrock_region
      DEFAULT_AWS_REGION = var.aws_region
      # LangFuse observability (optional)
      LANGFUSE_PUBLIC_KEY = var.langfuse_public_key
      LANGFUSE_SECRET_KEY = var.langfuse_secret_key
      LANGFUSE_HOST       = var.langfuse_host
      OPENAI_API_KEY      = var.openai_api_key
    }
  }
  
  tags = merge(
    local.common_tags,
    {
      Agent   = "tagger"
    }
  )
  
  depends_on = [aws_s3_object.lambda_packages["tagger"]]
}

# Reporter Lambda
resource "aws_lambda_function" "reporter" {
  function_name = "${local.name_prefix}-reporter"
  role          = aws_iam_role.lambda_agents_role.arn
  
  # Using S3 for deployment package (>50MB)
  s3_bucket        = aws_s3_bucket.lambda_packages.id
  s3_key           = aws_s3_object.lambda_packages["reporter"].key
  source_code_hash = fileexists("${path.module}/../../app/agents/reporter/reporter_lambda.zip") ? filebase64sha256("${path.module}/../../app/agents/reporter/reporter_lambda.zip") : null
  
  handler     = "lambda_handler.lambda_handler"
  runtime     = "python3.12"
  timeout     = 300  # 5 minutes for reporter agent
  memory_size = 1024
  
  environment {
    variables = {
      AURORA_CLUSTER_ARN = "${data.terraform_remote_state.db.outputs.aurora_cluster_arn}"
      AURORA_SECRET_ARN  = "${data.terraform_remote_state.db.outputs.aurora_secret_arn}"
      DATABASE_NAME      = "fp"
      BEDROCK_MODEL_ID   = var.bedrock_model_id
      BEDROCK_REGION     = var.bedrock_region
      DEFAULT_AWS_REGION = var.aws_region
      SAGEMAKER_ENDPOINT = "${data.terraform_remote_state.sagemaker.outputs.sagemaker_endpoint_name}"
      # LangFuse observability (optional)
      LANGFUSE_PUBLIC_KEY = var.langfuse_public_key
      LANGFUSE_SECRET_KEY = var.langfuse_secret_key
      LANGFUSE_HOST       = var.langfuse_host
      OPENAI_API_KEY      = var.openai_api_key
    }
  }

  tags = merge(
    local.common_tags,
    {
      Agent   = "reporter"
    }
  )
  
  depends_on = [aws_s3_object.lambda_packages["reporter"]]
}

# Charter Lambda
resource "aws_lambda_function" "charter" {
  function_name = "${local.name_prefix}-charter"
  role          = aws_iam_role.lambda_agents_role.arn
  
  # Using S3 for deployment package (>50MB)
  s3_bucket        = aws_s3_bucket.lambda_packages.id
  s3_key           = aws_s3_object.lambda_packages["charter"].key
  source_code_hash = fileexists("${path.module}/../../app/agents/charter/charter_lambda.zip") ? filebase64sha256("${path.module}/../../app/agents/charter/charter_lambda.zip") : null
  
  handler     = "lambda_handler.lambda_handler"
  runtime     = "python3.12"
  timeout     = 300  # 5 minutes for charter agent
  memory_size = 1024
  
  environment {
    variables = {
      AURORA_CLUSTER_ARN = "${data.terraform_remote_state.db.outputs.aurora_cluster_arn}"
      AURORA_SECRET_ARN  = "${data.terraform_remote_state.db.outputs.aurora_secret_arn}"
      DATABASE_NAME      = "fp"
      BEDROCK_MODEL_ID   = var.bedrock_model_id
      BEDROCK_REGION     = var.bedrock_region
      DEFAULT_AWS_REGION = var.aws_region
      # LangFuse observability (optional)
      LANGFUSE_PUBLIC_KEY = var.langfuse_public_key
      LANGFUSE_SECRET_KEY = var.langfuse_secret_key
      LANGFUSE_HOST       = var.langfuse_host
      OPENAI_API_KEY      = var.openai_api_key
    }
  }

  tags = merge(
    local.common_tags,
    {
      Agent = "charter"
    }
  )
  
  depends_on = [aws_s3_object.lambda_packages["charter"]]
}

# Retirement Lambda
resource "aws_lambda_function" "retirement" {
  function_name = "${local.name_prefix}-retirement"
  role          = aws_iam_role.lambda_agents_role.arn
  
  # Using S3 for deployment package (>50MB)
  s3_bucket        = aws_s3_bucket.lambda_packages.id
  s3_key           = aws_s3_object.lambda_packages["retirement"].key
  source_code_hash = fileexists("${path.module}/../../app/agents/retirement/retirement_lambda.zip") ? filebase64sha256("${path.module}/../../app/agents/retirement/retirement_lambda.zip") : null
  
  handler     = "lambda_handler.lambda_handler"
  runtime     = "python3.12"
  timeout     = 300  # 5 minutes for retirement agent
  memory_size = 1024
  
  environment {
    variables = {
      AURORA_CLUSTER_ARN = "${data.terraform_remote_state.db.outputs.aurora_cluster_arn}"
      AURORA_SECRET_ARN  = "${data.terraform_remote_state.db.outputs.aurora_secret_arn}"
      DATABASE_NAME      = "fp"
      BEDROCK_MODEL_ID   = var.bedrock_model_id
      BEDROCK_REGION     = var.bedrock_region
      DEFAULT_AWS_REGION = var.aws_region
      # LangFuse observability (optional)
      LANGFUSE_PUBLIC_KEY = var.langfuse_public_key
      LANGFUSE_SECRET_KEY = var.langfuse_secret_key
      LANGFUSE_HOST       = var.langfuse_host
      OPENAI_API_KEY      = var.openai_api_key
    }
  }

  tags = merge(
    local.common_tags,
    {
      Agent   = "retirement"
    }
  )
  
  depends_on = [aws_s3_object.lambda_packages["retirement"]]
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "agent_logs" {
  for_each = toset(["planner", "tagger", "reporter", "charter", "retirement"])
  
  name              = "/aws/lambda/${local.name_prefix}-${each.key}"
  retention_in_days = 7
  
  tags = merge(
    local.common_tags,
    {
      Agent   = each.key
    }
  )
}