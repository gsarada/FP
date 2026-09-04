output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.id
}

output "github_role_name" {
    value = aws_iam_role.this.*.arn
}