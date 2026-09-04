data "terraform_remote_state" "sagemaker" {
  backend = "s3"

  config = {
    bucket = var.backend_bucket_name
    key    = "env:/${var.environment}/sagemaker/terraform.tfstate"
    region = var.aws_region
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

data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket = var.backend_bucket_name
    key    = "env:/${var.environment}/database/terraform.tfstate"
    region = var.aws_region
  }
}

