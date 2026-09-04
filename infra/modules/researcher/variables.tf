variable "aws_region" {
  description = "AWS region for resources"
  type        = string
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


variable "scheduler_enabled" {
  description = "Enable automated research scheduler"
  type        = bool
  default     = false
}

variable "researcher_image_uri" {
  description = "Full ECR image URI for the researcher Lambda container"
  type        = string
  default     = ""
}

variable "bedrock_region" {
  description = "AWS region used for Bedrock model inference"
  type        = string
  default     = "ap-southeast-1"
}

variable "researcher_model" {
  description = "Bedrock model identifier used by the researcher"
  type        = string
  default     = "bedrock/global.openai.gpt-oss-120b-1:0"
}

variable "mcp_logging" {
  description = "Set to exact string True to enable researcher MCP logging"
  type        = string
  default     = "False"
}
