variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to every resource name (e.g. 'contact-form')."
  type        = string
  default     = "contact-form"
}

variable "to_email" {
  description = "Verified SES email address that receives contact form submissions."
  type        = string
}

variable "from_email" {
  description = "Verified SES email address (or domain identity) used as the sender."
  type        = string
}

variable "allowed_origins" {
  description = "List of origins permitted by CORS and the Lambda handler. Use [\"*\"] to allow any origin."
  type        = list(string)
  default     = ["*"]
}

variable "enable_waf" {
  description = "Whether to create and attach a WAFv2 WebACL with IP-based rate limiting."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Maximum number of requests per 5-minute window per IP before WAF blocks them."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default = {
    Project     = "contact-form"
    ManagedBy   = "terraform"
    Environment = "production"
  }
}
