locals {
  name_prefix = "fp-${var.environment}"

  common_tags = {
    Project     = "fp"
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "sagemaker"
  }
}

# IAM role for SageMaker
resource "aws_iam_role" "sagemaker_role" {
  name = "${local.name_prefix}-sagemaker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
      }
    ]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "sagemaker_full_access" {
  role       = aws_iam_role.sagemaker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

# SageMaker Model
resource "aws_sagemaker_model" "embedding_model" {
  name               = "${local.name_prefix}-embedding-model"
  execution_role_arn = aws_iam_role.sagemaker_role.arn

  primary_container {
    image = var.sagemaker_image_uri
    environment = {
      HF_MODEL_ID = var.embedding_model_name
      HF_TASK     = "feature-extraction"
    }
  }
  tags = local.common_tags
  depends_on = [aws_iam_role_policy_attachment.sagemaker_full_access]
}

# Serverless Inference Config
resource "aws_sagemaker_endpoint_configuration" "serverless_config" {
  name = "${local.name_prefix}-embedding-serverless-config"

  production_variants {
    model_name = aws_sagemaker_model.embedding_model.name
    
    serverless_config {
      memory_size_in_mb = 3072
      max_concurrency   = 2  # Reduced from 10 to avoid quota limit
    }
  }
}

# Add a delay for IAM role propagation before creating endpoint
resource "time_sleep" "wait_for_iam_propagation" {
  depends_on = [
    aws_iam_role_policy_attachment.sagemaker_full_access
  ]
  
  create_duration = "15s"
}

# SageMaker Endpoint
resource "aws_sagemaker_endpoint" "embedding_endpoint" {
  name                 = "${local.name_prefix}-embedding-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.serverless_config.name
  
  depends_on = [
    time_sleep.wait_for_iam_propagation
  ]
  
}