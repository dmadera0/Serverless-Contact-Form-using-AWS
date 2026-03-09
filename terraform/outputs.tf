output "api_endpoint" {
  description = "Invoke URL for the contact form POST endpoint."
  value       = "${aws_apigatewayv2_stage.default.invoke_url}/contact"
}

output "lambda_function_name" {
  description = "Name of the Lambda function."
  value       = aws_lambda_function.contact_handler.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function."
  value       = aws_lambda_function.contact_handler.arn
}

output "api_gateway_id" {
  description = "ID of the API Gateway HTTP API."
  value       = aws_apigatewayv2_api.contact_api.id
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group name for the Lambda function."
  value       = aws_cloudwatch_log_group.lambda.name
}
