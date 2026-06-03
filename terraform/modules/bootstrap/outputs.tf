output "bucket_id" {
  description = "S3 bucket name for use in backend configuration"
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.state.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for use in backend configuration"
  value       = aws_dynamodb_table.lock.name
}