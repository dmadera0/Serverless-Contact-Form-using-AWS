# ---------------------------------------------------------------------------
# Terraform configuration block
# Declares the minimum Terraform version and the external providers this
# project depends on. Terraform will download these automatically on
# `terraform init`.
#
#   aws     — the official HashiCorp provider for all AWS resources
#   archive — used to zip the Lambda source code before uploading it
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# Tell the AWS provider which region to deploy everything into.
# The value comes from var.aws_region (default: us-east-1).
provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Lambda deployment package
# ---------------------------------------------------------------------------

# Zip the contents of the ../lambda directory into lambda.zip.
# Terraform computes a SHA-256 hash of the zip so it can detect when the
# source code changes and automatically re-deploy the Lambda function.
# node_modules is excluded because it would bloat the zip unnecessarily —
# wait, actually node_modules IS needed at runtime since we ship the SDK.
# The archive provider excludes only the lock file artifact that npm writes.
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"   # path relative to this .tf file
  output_path = "${path.module}/../lambda.zip"
  excludes    = ["node_modules", ".package-lock.json"]
}

# ---------------------------------------------------------------------------
# IAM — Identity and Access Management
#
# AWS services can only talk to each other when you explicitly grant
# permission through IAM. Here we need two things:
#   1. An IAM Role that the Lambda function assumes when it runs.
#   2. Policies attached to that role that say what Lambda is allowed to do.
# ---------------------------------------------------------------------------

# This policy document defines the "trust relationship" for the role —
# it answers the question "which AWS service is allowed to assume this role?"
# We're saying: only the Lambda service (lambda.amazonaws.com) can use it.
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Create the IAM role that Lambda will assume at runtime.
# The assume_role_policy above controls who can use this role.
resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

# Attach the AWS-managed policy AWSLambdaBasicExecutionRole to the role.
# This grants Lambda permission to write its logs to CloudWatch — without
# this, you would get an "AccessDenied" error and see no logs at all.
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Define a custom policy document that allows Lambda to send emails via SES.
# The condition block is a security best practice — it locks the permission
# down so that Lambda can ONLY send email from the specific FROM_EMAIL address,
# not from any address in your AWS account.
data "aws_iam_policy_document" "ses_send" {
  statement {
    sid     = "AllowSESSend"
    effect  = "Allow"
    actions = ["ses:SendEmail", "ses:SendRawEmail"]

    resources = ["*"]

    # StringEquals condition: the ses:FromAddress key in the request must
    # exactly match var.from_email. If someone tries to spoof a different
    # sender, SES will deny the request.
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.from_email]
    }
  }
}

# Attach the SES policy directly to the role as an inline policy.
# Unlike managed policies, inline policies are deleted when the role is deleted.
resource "aws_iam_role_policy" "ses_send" {
  name   = "${var.project_name}-ses-send"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.ses_send.json
}

# ---------------------------------------------------------------------------
# CloudWatch log groups
#
# CloudWatch is AWS's logging and monitoring service. We create the log
# groups in Terraform so we can control the retention period (how long logs
# are kept before being auto-deleted). If we didn't create them here,
# Lambda and API Gateway would create them automatically but with infinite
# retention, which costs money over time.
# ---------------------------------------------------------------------------

# Log group for Lambda output. Lambda writes here automatically because
# AWSLambdaBasicExecutionRole grants it permission. The naming convention
# /aws/lambda/<function-name> is required by AWS.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-handler"
  retention_in_days = 14  # logs are deleted after 14 days to manage cost
  tags              = var.tags
}

# Log group for API Gateway access logs (who called the API, what HTTP
# status they got, how long it took, etc.). We reference this group's ARN
# in the API Gateway stage configuration below.
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 14
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# Lambda function
#
# Lambda is the serverless compute service that runs our contact form code.
# You only pay for the milliseconds your code is actually executing —
# there are no servers to manage or keep running.
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "contact_handler" {
  function_name = "${var.project_name}-handler"

  # The IAM role Lambda will assume when it runs (defined above).
  role = aws_iam_role.lambda_exec.arn

  # The language runtime Lambda should use to execute the code.
  runtime = "nodejs20.x"

  # "handler" tells Lambda which file and exported function to call.
  # Format: <filename without .js>.<exported function name>
  # So "index.handler" means: call the `handler` export in index.js.
  handler = "index.handler"

  # Point Lambda at the zip we created with archive_file above.
  filename         = data.archive_file.lambda_zip.output_path

  # Terraform uses this hash to detect when source code has changed.
  # If the hash changes, Terraform will upload a new version of the zip.
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  memory_size = 128  # MB — 128 MB is plenty for a simple email sender
  timeout     = 10   # seconds — how long Lambda waits before force-killing

  # Environment variables are injected at runtime and accessible in Node
  # via process.env.VARIABLE_NAME. This avoids hardcoding secrets in code.
  environment {
    variables = {
      TO_EMAIL        = var.to_email
      FROM_EMAIL      = var.from_email
      ALLOWED_ORIGINS = join(",", var.allowed_origins)  # list → comma string
    }
  }

  # depends_on ensures the log group exists before Lambda is created,
  # so the very first invocation can write logs without a race condition.
  # It also ensures the basic execution role is attached before Lambda runs.
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.lambda_basic_execution,
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# API Gateway HTTP API (v2)
#
# API Gateway is the "front door" that sits between the internet and Lambda.
# It handles HTTPS, routing, CORS headers, and access logging so Lambda
# doesn't have to. We use the newer HTTP API (v2) which is cheaper and
# faster than the original REST API (v1).
#
# The flow for each request is:
#   Internet → API (CORS check) → Integration (pass to Lambda) → Route (match URL)
# ---------------------------------------------------------------------------

# The API itself. protocol_type = "HTTP" selects the HTTP API (v2) product.
# The cors_configuration block tells API Gateway to automatically add the
# correct Access-Control-* response headers so browsers allow cross-origin
# requests from your frontend domain.
resource "aws_apigatewayv2_api" "contact_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_origins       # e.g. ["https://yoursite.com"]
    allow_methods = ["POST", "OPTIONS"]        # OPTIONS is needed for preflight
    allow_headers = ["Content-Type"]           # the only header our form sends
    max_age       = 300                        # browsers can cache preflight for 5 min
  }

  tags = var.tags
}

# The integration wires API Gateway to Lambda.
# AWS_PROXY means API Gateway passes the full HTTP request to Lambda as-is
# and Lambda is responsible for building the entire HTTP response.
# payload_format_version = "2.0" is the modern format (simpler event shape).
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.contact_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.contact_handler.invoke_arn
  payload_format_version = "2.0"
}

# A route maps an HTTP method + path to an integration.
# "POST /contact" means: when a POST request arrives at /contact,
# forward it to the Lambda integration defined above.
resource "aws_apigatewayv2_route" "post_contact" {
  api_id    = aws_apigatewayv2_api.contact_api.id
  route_key = "POST /contact"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# A stage is a named deployment environment (like "prod", "staging").
# "$default" is a special stage that serves traffic at the root URL
# without a stage prefix. auto_deploy = true means any route/integration
# change is deployed immediately without a manual deploy action.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.contact_api.id
  name        = "$default"
  auto_deploy = true

  # Access logging records one structured JSON line per HTTP request.
  # $context.* are API Gateway runtime variables — they're resolved to
  # real values (IP address, status code, etc.) for each request.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      sourceIp         = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      protocol         = "$context.protocol"
      httpMethod       = "$context.httpMethod"
      resourcePath     = "$context.resourcePath"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Lambda invoke permission for API Gateway
#
# IAM roles (above) control what Lambda can DO. But to control what can
# CALL Lambda, we use a Lambda resource-based policy via aws_lambda_permission.
# Without this, API Gateway would get an "Access Denied" when it tries to
# invoke the function, even though the API is set up correctly.
# ---------------------------------------------------------------------------

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.contact_handler.function_name
  principal     = "apigateway.amazonaws.com"  # the service being granted access

  # source_arn restricts which specific API can invoke Lambda.
  # The pattern /*/*  means "any stage, any route" within this API.
  # This prevents other APIs in the same AWS account from invoking our function.
  source_arn = "${aws_apigatewayv2_api.contact_api.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Optional WAF (Web Application Firewall)
#
# WAF sits in front of API Gateway and can inspect/block requests before
# they ever reach Lambda. Here we use it purely for IP-based rate limiting,
# which prevents a single IP address from flooding the contact form.
#
# These resources are conditional — they are only created when
# var.enable_waf = true. Terraform uses `count` to achieve this:
#   count = 1  →  resource is created
#   count = 0  →  resource is skipped entirely
# ---------------------------------------------------------------------------

# The WebACL (Web Access Control List) is the WAF itself.
# It contains an ordered list of rules evaluated top-to-bottom.
resource "aws_wafv2_web_acl" "contact_waf" {
  # Ternary expression: if enable_waf is true create 1 instance, else 0.
  count = var.enable_waf ? 1 : 0

  name = "${var.project_name}-waf"

  # REGIONAL scope protects resources inside a specific AWS region,
  # which is correct for API Gateway. (CLOUDFRONT is the other option.)
  scope = "REGIONAL"

  # The default action applies to any request that doesn't match a rule.
  # We default to allow so only rate-limit violators are blocked.
  default_action {
    allow {}
  }

  rule {
    name     = "${var.project_name}-ip-rate-limit"
    priority = 1  # lower number = evaluated first

    # Action to take when this rule matches (rate limit exceeded).
    action {
      block {}
    }

    statement {
      rate_based_statement {
        # Maximum number of requests allowed from a single IP in any
        # rolling 5-minute window. Requests beyond this are blocked.
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"  # count requests per unique IP address
      }
    }

    # visibility_config enables CloudWatch metrics for this specific rule
    # so you can graph and alert on how many requests are being rate-limited.
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # Top-level visibility config for the WebACL as a whole.
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# Associate the WAF WebACL with the API Gateway stage so it actually
# intercepts traffic. Without this association the WebACL exists but
# does nothing. The [0] index is required because count makes this a list.
resource "aws_wafv2_web_acl_association" "contact_waf_assoc" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = aws_wafv2_web_acl.contact_waf[0].arn
}
