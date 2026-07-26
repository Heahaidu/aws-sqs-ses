terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8.0"
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
  description = "Lambda code lang"
  default     = "nodejs24.x"
}

variable "ses_from_address" {
  description = "SES Identity email"
  default     = "noreply@heahaidu.me"
}

# ---------------------------------------------------------------------------
# 0. SES - Email identity
# ---------------------------------------------------------------------------
resource "aws_sesv2_email_identity" "main" {
  email_identity = "heahaidu.me"

  configuration_set_name = aws_sesv2_configuration_set.main.configuration_set_name

  depends_on = [ aws_sesv2_configuration_set.main ]

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# 1. DynamoDB — save bounce email
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "bounce_email_table" {
  name         = "bounce-email-table"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "email"

  attribute {
    name = "email"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# 2. Dead Letter Queue — save fail messages
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "email_dlq" {
  name                      = "ses-email-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# ---------------------------------------------------------------------------
# 3. Main Queue
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "email_queue" {
  name                       = "ses-email-queue"
  visibility_timeout_seconds = 60    # >= maximum time in second that lambda handler each batch
  message_retention_seconds  = 86400 # 1 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.email_dlq.arn
    maxReceiveCount     = 3 # retry 3 times before DLQ
  })
}

# ---------------------------------------------------------------------------
# 4. SNS - Bounce Notification
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "bounce_email" {
  name = "sns-bounce-complaint-email"
}

# resource "aws_sns_topic_policy" "bounce_email_policy" {
#   arn = aws_sns_topic.bounce_email.arn

#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect    = "Allow"
#         Principal = { Service = "ses.amazonaws.com" }
#         Action    = "sns:Publish"
#         Resource  = aws_sns_topic.bounce_email.arn
#         # Condition = {
#         #   StringLike = {
#         #     "AWS:SourceArn" = aws_sesv2_email_identity.main.arn
#         #   }
#         # }
#       }
#     ]
#   })
# }

# ---------------------------------------------------------------------------
# 5. SES - Email Notifications
# ---------------------------------------------------------------------------
resource "aws_sesv2_configuration_set" "main" {
  configuration_set_name = "ses-bounce-complaint-notification"
}

resource "aws_sesv2_configuration_set_event_destination" "bounce_notification" {
  configuration_set_name = aws_sesv2_configuration_set.main.configuration_set_name
  event_destination_name = "sns-bounce-complaint-email"

  event_destination {
    enabled              = true
    matching_event_types = ["BOUNCE"]
    sns_destination {
      topic_arn = aws_sns_topic.bounce_email.arn
    }
  }
  
}

# ---------------------------------------------------------------------------
# 6. IAM Role for Lambda (send_email)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "lambda_email_handler_role" {
  name = "lambda-email-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_email_hander_policy" {
  name = "lambda-email-handler-policy"
  role = aws_iam_role.lambda_email_handler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = [ aws_sesv2_email_identity.main.arn, aws_sesv2_configuration_set.main.arn ]
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
      },
      {
        Effect   = "Allow",
        Action   = "dynamodb:GetItem"
        Resource = aws_dynamodb_table.bounce_email_table.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# 7. IAM Role for Lambda (bounce_email)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lambda_bounce_email_handler_role" {
  name = "lambda-email-bounce-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_bounce_email_hander_policy" {
  name = "lambda-email-bounce-handler-policy"
  role = aws_iam_role.lambda_bounce_email_handler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow",
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.bounce_email_table.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# 8. Zip folder
# ---------------------------------------------------------------------------
data "archive_file" "zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda-nodejs"
  output_path = "${path.module}/../lambda-nodejs.zip"
}
# ---------------------------------------------------------------------------
# 9. Lambda Function (send_email)
#    Node:   cd lambda-nodejs && zip -r ../lambda-nodejs.zip .
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "send_email" {
  function_name    = "ses-email-sender"
  role             = aws_iam_role.lambda_email_handler_role.arn
  runtime          = var.runtime
  handler          = "send-email/index.handler"
  filename         = "../lambda-nodejs.zip"
  source_code_hash = filebase64sha256("../lambda-nodejs.zip")

  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      SES_FROM_ADDRESS = var.ses_from_address
      AWS_REGION_SES   = var.aws_region
      TABLE_NAME       = aws_dynamodb_table.bounce_email_table.name
    }
  }
}

# ---------------------------------------------------------------------------
# 10. Event Source Mapping — SQS "trigger" Lambda (send_email)
# ---------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "sqs_send_email_trigger" {
  event_source_arn = aws_sqs_queue.email_queue.arn
  function_name    = aws_lambda_function.send_email.arn
  batch_size       = 10

  scaling_config {
    maximum_concurrency = 2
  }
}

# ---------------------------------------------------------------------------
# 11. Lambda Function (bounce_email)
#    Node:   cd lambda-nodejs && zip -r ../lambda-nodejs.zip .
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "bounce_email" {
  function_name    = "ses-email-bounce"
  role             = aws_iam_role.lambda_bounce_email_handler_role.arn
  runtime          = var.runtime
  handler          = "bounce-email/index.handler"
  filename         = "../lambda-nodejs.zip"
  source_code_hash = filebase64sha256("../lambda-nodejs.zip")

  timeout     = 30
  memory_size = 128


  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.bounce_email_table.name
    }
  }
}

# ---------------------------------------------------------------------------
# 12. Event Subcription — SNS "trigger" Lambda (bounce_email)
# ---------------------------------------------------------------------------
resource "aws_sns_topic_subscription" "sns_bounce_trigger" {
  topic_arn = aws_sns_topic.bounce_email.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.bounce_email.arn
}

# ---------------------------------------------------------------------------
# 13. Lambda Permission — SNS "Invoke" Lambda (bounce_email)
# ---------------------------------------------------------------------------
resource "aws_lambda_permission" "lambda_bounce_email_allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bounce_email.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.bounce_email.arn

}
# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "queue_url" {
  value = aws_sqs_queue.email_queue.id
}
