variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "backend_bucket_name" {
  description = "Name of the backend bucket where state is stored"
  type        = string
}

variable "bedrock_region" {
  description = "AWS region for Bedrock (may differ from main region)"
  type        = string
  default     = "us-west-2"
}

variable "bedrock_model_id" {
  description = "Bedrock model ID to monitor (e.g., amazon.nova-pro-v1:0)"
  type        = string
  default     = "amazon.nova-pro-v1:0"
}