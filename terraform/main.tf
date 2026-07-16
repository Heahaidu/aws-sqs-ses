terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "runtime" {
  description = "python3.14 or nodejs24.x"
  default     = "nodejs24.x" 
}

variable "ses_from_address" {
  description = "SES Identity email"
  default     = "noreply@heahaidu.me"
}

# ---------------------------------------------------------------------------
# 1. Dead Letter Queue — save fail messages
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "email_dlq" {
  name                      = "ses-email-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# ---------------------------------------------------------------------------
# 2. Main Queue
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "email_queue" {
  name                       = "ses-email-queue"
  visibility_timeout_seconds = 60   # >= maximum time in second that lambda handler each batch
  message_retention_seconds  = 86400 # 1 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.email_dlq.arn
    maxReceiveCount      = 3 # retry 3 times before DLQ
  })
}

# ---------------------------------------------------------------------------
# 3. IAM Role for Lambda
# ---------------------------------------------------------------------------
resource "aws_iam_role" "lambda_role" {
  name = "ses-email-sender-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "ses-email-sender-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "arn:aws:ses:us-east-1:852368830719:identity/heahaidu.me"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.email_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# 4. Lambda Function
#    Python: cd lambda-python && zip -r ../lambda-python.zip .
#    Node:   cd lambda-nodejs && zip -r ../lambda-nodejs.zip .
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "send_email" {
  function_name = "ses-email-sender"
  role          = aws_iam_role.lambda_role.arn
  runtime       = var.runtime
  handler       = var.runtime == "nodejs24.x" ? "index.handler" : "handler.handler"
  filename      = var.runtime == "nodejs24.x" ? "../lambda-nodejs.zip" : "../lambda-python.zip"
  timeout       = 30
  memory_size   = 128

  reserved_concurrent_executions = 1

  environment {
    variables = {
      SES_FROM_ADDRESS = var.ses_from_address
      AWS_REGION_SES   = var.aws_region
    }
  }
}

# ---------------------------------------------------------------------------
# 5. Event Source Mapping — SQS "trigger" Lambda
# ---------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.email_queue.arn
  function_name    = aws_lambda_function.send_email.arn
  batch_size       = 10

  scaling_config {
    maximum_concurrency = 2 
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "queue_url" {
  value = aws_sqs_queue.email_queue.id
}

output "dlq_url" {
  value = aws_sqs_queue.email_dlq.id
}

output "lambda_function_name" {
  value = aws_lambda_function.send_email.function_name
}
