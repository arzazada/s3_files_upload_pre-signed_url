# S3 Bucket for Static Website Hosting
resource "aws_s3_bucket" "frontend" {
  bucket = "myapp-frontend"
}

# S3 Bucket for Storing Uploaded Files
resource "aws_s3_bucket" "uploads" {
  bucket = "myapp-uploads"
}

# S3 Bucket Website Configuration
resource "aws_s3_bucket_website_configuration" "frontend_website" {
  bucket = aws_s3_bucket.frontend.bucket

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# S3 Bucket Public Access Block
resource "aws_s3_bucket_public_access_block" "public_access_block" {
  bucket                    = aws_s3_bucket.frontend.id
  block_public_acls         = false
  block_public_policy       = false
  ignore_public_acls        = false
  restrict_public_buckets   = false
}

# S3 Bucket Policy to Allow Public Access for Website Bucket
resource "aws_s3_bucket_policy" "frontend_policy" {
  depends_on = [aws_s3_bucket_public_access_block.public_access_block]
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "s3:GetObject",
        Effect   = "Allow",
        Resource = "${aws_s3_bucket.frontend.arn}/*",
        Principal = "*"
      },
    ],
  })
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "lambda_s3_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
      },
    ],
  })
}

# IAM Policy for Lambda to access S3
resource "aws_iam_policy" "lambda_s3_policy" {
  name        = "lambda_s3_policy"
  description = "Policy for Lambda to access S3"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = [
          "s3:PutObject",
          "s3:GetObject"
        ],
        Effect   = "Allow",
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
    ],
  })
}

# Attach IAM Policy to Lambda Role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

###   Lambda Function
resource "aws_lambda_function" "file_upload_function" {
  function_name    = "file_upload_function"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9"
  timeout          = 30

  filename         = "${path.root}/files/lambda_function.zip"
  source_code_hash = filebase64sha256("${path.root}/files/lambda_function.zip")

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.uploads.bucket
    }
  }
}

# API Gateway for Lambda
resource "aws_api_gateway_rest_api" "file_upload_api" {
  name        = "file_upload_api"
  description = "API Gateway for File Upload to S3 via Lambda"
}

resource "aws_api_gateway_resource" "upload" {
  rest_api_id = aws_api_gateway_rest_api.file_upload_api.id
  parent_id   = aws_api_gateway_rest_api.file_upload_api.root_resource_id
  path_part   = "presigned-url"
}

resource "aws_api_gateway_method" "upload_post" {
  rest_api_id   = aws_api_gateway_rest_api.file_upload_api.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_integration" {
  rest_api_id             = aws_api_gateway_rest_api.file_upload_api.id
  resource_id             = aws_api_gateway_resource.upload.id
  http_method             = aws_api_gateway_method.upload_post.http_method
  integration_http_method = "GET"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.file_upload_function.invoke_arn

  depends_on = [aws_lambda_permission.apigw_lambda]
}


resource "aws_api_gateway_method_response" "post_response" {
  rest_api_id = aws_api_gateway_rest_api.file_upload_api.id
  resource_id = aws_api_gateway_resource.upload.id
  http_method = aws_api_gateway_method.upload_post.http_method
  status_code = 200


  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true,
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true
  }

  response_models = {
    "application/json" = "Empty"
  }
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "file_upload_deployment" {
  depends_on = [
    aws_api_gateway_integration.upload_integration
  ]
  rest_api_id = aws_api_gateway_rest_api.file_upload_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.upload.id,
      aws_api_gateway_method.upload_post.id,
      aws_api_gateway_integration.upload_integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  stage_name   = "prod"
  rest_api_id  = aws_api_gateway_rest_api.file_upload_api.id
  deployment_id = aws_api_gateway_deployment.file_upload_deployment.id

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw_log_group.arn
    format          = jsonencode({
      requestId       = "$context.requestId"
      ip              = "$context.identity.sourceIp"
      caller          = "$context.identity.caller"
      user            = "$context.identity.user"
      requestTime     = "$context.requestTime"
      httpMethod      = "$context.httpMethod"
      resourcePath    = "$context.resourcePath"
      status          = "$context.status"
      protocol        = "$context.protocol"
      responseLength  = "$context.responseLength"
      responsePayload = "$context.integration.response.body"
      requestPayload  = "$context.request.body"
      responseLatency = "$context.responseLatency"
    })
  }

  xray_tracing_enabled = false

  variables = {
    "CloudWatchLogRoleArn" = aws_iam_role.api_gateway_cloudwatch_role.arn
  }
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_upload_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.file_upload_api.execution_arn}/*/*"
}

# CloudWatch Role for API Gateway
resource "aws_iam_role" "api_gateway_cloudwatch_role" {
  name = "APIGatewayCloudWatchLogsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "apigateway.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach CloudWatch Logs Policy to IAM Role
resource "aws_iam_policy_attachment" "cloudwatch_logs_attach" {
  name       = "attach-cloudwatch-logs"
  roles      = [aws_iam_role.api_gateway_cloudwatch_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# API Gateway Stage Configuration

# Method Settings for API Gateway
resource "aws_api_gateway_method_settings" "example" {
  rest_api_id = aws_api_gateway_rest_api.file_upload_api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
    logging_level   = "INFO"
  }
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gw_log_group" {
  name              = "/aws/api-gateway/file_upload_api"
  retention_in_days = 7
}

# API Gateway Account Configuration
resource "aws_api_gateway_account" "demo" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch_role.arn
}

###  Outputs
output "website_url" {
  value = aws_s3_bucket_website_configuration.frontend_website.website_endpoint
}

output "api_endpoint2" {
  value = "https://${aws_api_gateway_rest_api.file_upload_api.id}.execute-api.${var.region}.amazonaws.com/prod/upload"
}


###########################
###########################
#
#data "aws_route53_zone" "main" {
#  name         = var.domain
#  private_zone = false
#}
#
#resource "aws_acm_certificate" "cert" {
#
#  provider          = aws.us-east-1
#  domain_name       = var.domain # Replace with your domain
#  validation_method = "DNS"
#
#  subject_alternative_names = [
#    "upload.${var.domain}"
#  ]
#
#  lifecycle {
#    create_before_destroy = true
#  }
#}
#
#resource "aws_route53_record" "cert_validation" {
#  for_each = {
#    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
#      name   = dvo.resource_record_name
#      type   = dvo.resource_record_type
#      value  = dvo.resource_record_value
#    }
#  }
#
#  zone_id = data.aws_route53_zone.main.zone_id
#  name    = each.value.name
#  type    = each.value.type
#  records = [each.value.value]
#  ttl     = 300
#}
#
#resource "aws_acm_certificate_validation" "cert_validation" {
#  provider                = aws.us-east-1
#  certificate_arn         = aws_acm_certificate.cert.arn
#  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
#}
#
#
#
## CloudFront Distribution
#resource "aws_cloudfront_distribution" "s3_distribution" {
#  origin {
#    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
#    origin_id   = "S3-${aws_s3_bucket.frontend.bucket}"
#
#    s3_origin_config {
#      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
#    }
#  }
#
#  enabled             = true
#  is_ipv6_enabled     = true
#  comment             = "S3 static website for myapp"
#  default_root_object = "index.html"
#
#  aliases = ["upload.${var.domain}"]
#
#  default_cache_behavior {
#    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
#    cached_methods   = ["GET", "HEAD"]
#    target_origin_id = "S3-${aws_s3_bucket.frontend.bucket}"
#
#    forwarded_values {
#      query_string = false
#      cookies {
#        forward = "none"
#      }
#    }
#
#
#    viewer_protocol_policy = "redirect-to-https"
#
#    min_ttl                = 0
#    default_ttl            = 3600
#    max_ttl                = 86400
#  }
#
#  viewer_certificate {
#    acm_certificate_arn            = aws_acm_certificate.cert.arn
#    ssl_support_method              = "sni-only"
#    minimum_protocol_version        = "TLSv1.2_2019"
#  }
#
#
#  restrictions {
#    geo_restriction {
#      restriction_type = "none"
#    }
#  }
#}
#
#resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
#  comment = "Origin Access Identity for S3"
#}
#
#output "cloudfront_domain_name" {
#  value = aws_cloudfront_distribution.s3_distribution.domain_name
#}
#
#resource "aws_route53_record" "www" {
#  zone_id = data.aws_route53_zone.main.zone_id
#  name    = "upload.${var.domain}"
#  type    = "A"
#
#  alias {
#    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
#    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
#    evaluate_target_health = false
#  }
#}
