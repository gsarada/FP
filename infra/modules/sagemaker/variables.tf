variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "ap-southeast-1"
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

# Ref https://aws.github.io/deep-learning-containers/reference/available_images/ for latest image uri
variable "sagemaker_image_uri" {
  description = "URI of the SageMaker container image"
  type        = string
  default     = "763104351884.dkr.ecr.ap-southeast-1.amazonaws.com/huggingface-pytorch-inference:2.6.0-transformers5.5.3-cpu-py312-ubuntu22.04"
}

variable "embedding_model_name" {
  description = "Name of the HuggingFace model to use"
  type        = string
  default     = "sentence-transformers/all-MiniLM-L6-v2"
}