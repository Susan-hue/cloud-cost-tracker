terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

output "cloudfront_url" {
  value = aws_cloudfront_distribution.dashboard.domain_name
}

# DynamoDB Table
resource "aws_dynamodb_table" "cost_logs" {
  name           = "CostUsageLogs"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# SNS Topic + Subscription
resource "aws_sns_topic" "billing_alerts" {
  name = "billing-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.billing_alerts.arn
  protocol  = "email"
  endpoint  = "amechisusanogechi@gmail.com"
}

# CloudWatch Alarm
resource "aws_cloudwatch_metric_alarm" "billing_alarm" {
  alarm_name          = "BillingAlarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600
  statistic           = "Maximum"
  threshold           = 0.01
  alarm_description   = "Alarm when AWS billing exceeds $0.01"
  actions_enabled     = true

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.billing_alerts.arn]
}

# IAM Role for Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "lambda_logging_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# Lambda function
resource "aws_lambda_function" "log_costs" {
  function_name = "log_costs"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  filename      = "${path.module}/../Lambda/lambda_package.zip"


  environment {
    variables = {
      DDB_TABLE = aws_dynamodb_table.cost_logs.name
    }
  }
}

# EventBridge (scheduled run)
resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "daily_cost_logger"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "log_lambda" {
  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "log_costs"
  arn       = aws_lambda_function.log_costs.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_costs.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

# Allow SNS to invoke Lambda
resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSToInvokeLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_costs.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.billing_alerts.arn
}

resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.billing_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.log_costs.arn
}

# Random ID for unique bucket name
resource "random_id" "rand" {
  byte_length = 4
}

# S3 bucket for dashboard
resource "aws_s3_bucket" "dashboard" {
  bucket        = "cloud-cost-dashboard-${random_id.rand.hex}"
  force_destroy = true
}

# S3 ownership controls
resource "aws_s3_bucket_ownership_controls" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Public access
resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Policy to allow public read
resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = "*",
      Action    = ["s3:GetObject"],
      Resource  = "${aws_s3_bucket.dashboard.arn}/*"
    }]
  })
}

# Website hosting config
resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  index_document {
    suffix = "index.html"
  }
}

# Upload HTML file
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "index.html"
  source       = "${path.module}/../Frontend/index.html"
  content_type = "text/html"
}

# CloudFront distribution
resource "aws_cloudfront_distribution" "dashboard" {
  origin {
    domain_name = aws_s3_bucket.dashboard.bucket_regional_domain_name
    origin_id   = "s3-dashboard"
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    target_origin_id       = "s3-dashboard"
    viewer_protocol_policy = "allow-all"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# New Lambda for API 
resource "aws_lambda_function" "get_cost_logs" {
  function_name = "get_cost_logs"
  role          = aws_iam_role.lambda_role.arn
  handler       = "api_lambda.lambda_handler"
  runtime       = "python3.9"
  filename      = "${path.module}/../API_Integration/api_lambda_package.zip"   
  environment {
    variables = {
      DDB_TABLE = aws_dynamodb_table.cost_logs.name
    }
  }
}

# Allow Lambda logs + DynamoDB access (already attached before)
# No need to duplicate — just reuse the same IAM role.

# API Gateway (HTTP API)
resource "aws_apigatewayv2_api" "cost_api" {
  name          = "cost-tracker-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_methods = ["GET", "OPTIONS"]
    allow_origins = ["*"]
    allow_headers = ["*"]
  }
}


# Integration (API → Lambda)
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.cost_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.get_cost_logs.invoke_arn
}

# Route (GET /logs → Lambda)
resource "aws_apigatewayv2_route" "get_logs" {
  api_id    = aws_apigatewayv2_api.cost_api.id
  route_key = "GET /logs"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Stage (default stage, auto-deployed)
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.cost_api.id
  name        = "$default"
  auto_deploy = true
}

# Permission: Allow API Gateway to invoke Lambda
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_cost_logs.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.cost_api.execution_arn}/*/*"
}

# Output API URL
output "api_gateway_url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}

