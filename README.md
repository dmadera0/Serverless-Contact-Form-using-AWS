# Serverless Contact Form — AWS Lambda + API Gateway + SES

A production-ready, fully serverless contact form backend and frontend built with AWS Lambda (Node.js 20), API Gateway HTTP API v2, and Amazon SES, provisioned entirely with Terraform.

---

## Architecture

```
Browser (frontend/index.html)
        │
        │  HTTPS POST /contact
        ▼
┌──────────────────────────────┐
│   API Gateway HTTP API v2    │  ← CORS, access logs → CloudWatch
│   (POST /contact route)      │
└──────────┬───────────────────┘
           │  AWS_PROXY (payload 2.0)
           ▼
┌──────────────────────────────┐
│     AWS Lambda (Node 20)     │  ← Sanitize → Validate → Send
│     lambda/index.js          │
└──────────┬───────────────────┘
           │  ses:SendEmail
           ▼
┌──────────────────────────────┐
│     Amazon SES               │  → Recipient inbox
└──────────────────────────────┘
           │
           ▼
┌──────────────────────────────┐
│     CloudWatch Logs          │  /aws/lambda/...  /aws/apigateway/...
└──────────────────────────────┘

Optional:
┌──────────────────────────────┐
│     AWS WAFv2 (REGIONAL)     │  ← IP rate limiting → API Gateway stage
└──────────────────────────────┘
```

---

## Prerequisites

| Tool              | Version    | Purpose                          |
|-------------------|------------|----------------------------------|
| Node.js           | >= 20.x    | Lambda runtime / npm install     |
| npm               | >= 9.x     | Install `@aws-sdk/client-ses`    |
| Terraform         | >= 1.3     | Infrastructure provisioning      |
| AWS CLI           | >= 2.x     | Credentials + SES verification   |
| AWS account       | —          | Deployment target                |

---

## Step-by-Step Setup

### 1 — Verify SES email addresses

Both the sender and recipient email addresses must be verified in SES before emails can be sent. If your account is still in the **SES sandbox**, both addresses must be individually verified.

```bash
# Verify the sender
aws ses verify-email-identity --email-address noreply@example.com --region us-east-1

# Verify the recipient
aws ses verify-email-identity --email-address you@example.com --region us-east-1
```

Check the verification status:

```bash
aws ses get-identity-verification-attributes \
  --identities noreply@example.com you@example.com \
  --region us-east-1
```

> To send to any address (production), request SES production access to leave the sandbox.

---

### 2 — Install Lambda dependencies

```bash
cd lambda
npm install
cd ..
```

> The `@aws-sdk/client-ses` package must be present in `lambda/node_modules` when Terraform zips the directory. The `node_modules` folder is included in the zip (only `.package-lock.json` is excluded).

---

### 3 — Configure Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region   = "us-east-1"
project_name = "contact-form"
to_email     = "you@example.com"        # receives submissions
from_email   = "noreply@example.com"    # verified SES sender
allowed_origins = ["https://yoursite.com"]
enable_waf   = false
```

---

### 4 — Deploy with Terraform

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

After apply completes, note the outputs:

```
api_endpoint          = "https://abc123.execute-api.us-east-1.amazonaws.com/contact"
lambda_function_name  = "contact-form-handler"
lambda_function_arn   = "arn:aws:lambda:us-east-1:..."
api_gateway_id        = "abc123"
cloudwatch_log_group  = "/aws/lambda/contact-form-handler"
```

---

### 5 — Wire the frontend

Open [frontend/index.html](frontend/index.html) and replace the placeholder constant at the top of the `<script>` block:

```js
// Before
const API_ENDPOINT = 'https://YOUR_API_ID.execute-api.YOUR_REGION.amazonaws.com/contact';

// After
const API_ENDPOINT = 'https://abc123.execute-api.us-east-1.amazonaws.com/contact';
```

Serve `index.html` from any static host (S3 + CloudFront, GitHub Pages, Netlify, etc.).

---

## cURL Test Examples

### Successful submission

```bash
curl -s -X POST https://abc123.execute-api.us-east-1.amazonaws.com/contact \
  -H "Content-Type: application/json" \
  -d '{
    "name":    "Jane Smith",
    "email":   "jane@example.com",
    "subject": "Hello from cURL",
    "message": "This is a test message sent via cURL.",
    "phone":   "+1 555 123 4567"
  }' | jq .
```

Expected response:

```json
{
  "success": true,
  "message": "Your message has been sent successfully. We'll be in touch soon."
}
```

---

### Validation error

```bash
curl -s -X POST https://abc123.execute-api.us-east-1.amazonaws.com/contact \
  -H "Content-Type: application/json" \
  -d '{
    "name":    "J",
    "email":   "not-an-email",
    "subject": "Hi",
    "message": "Short"
  }' | jq .
```

Expected response (`422 Unprocessable Entity`):

```json
{
  "success": false,
  "errors": [
    { "field": "name",    "message": "Name must be at least 2 characters." },
    { "field": "email",   "message": "Please enter a valid email address." },
    { "field": "subject", "message": "Subject must be at least 3 characters." },
    { "field": "message", "message": "Message must be at least 10 characters." }
  ]
}
```

---

### CORS preflight

```bash
curl -s -X OPTIONS https://abc123.execute-api.us-east-1.amazonaws.com/contact \
  -H "Origin: https://yoursite.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type" \
  -I
```

---

## Security Features

| Feature                     | Implementation                                                          |
|-----------------------------|-------------------------------------------------------------------------|
| Input sanitization          | HTML tags stripped; max-length truncation on all fields                 |
| Server-side validation      | Name, email regex, subject, message length enforced in Lambda           |
| CORS restriction            | `ALLOWED_ORIGINS` env var; API Gateway CORS config matches              |
| SES IAM least privilege     | Inline policy scoped to `ses:FromAddress` via `StringEquals` condition  |
| No hardcoded credentials    | All secrets via environment variables and Terraform variables           |
| CloudWatch logging          | Lambda structured JSON logs; API Gateway JSON access logs               |
| WAF rate limiting (optional)| IP-based 5-minute sliding window via WAFv2 WebACL                       |
| Reply-To header             | Set to sender's email so replies go to them, not FROM_EMAIL             |
| HTML email escaping         | All user content HTML-escaped before rendering in email body            |

---

## Cost Estimate

Pricing based on AWS `us-east-1` as of 2025. Actual costs depend on volume.

| Service          | Free Tier                            | Beyond Free Tier                    |
|------------------|--------------------------------------|-------------------------------------|
| Lambda           | 1M requests + 400,000 GB-s / month   | ~$0.20 / 1M requests                |
| API Gateway HTTP | 1M requests / month (12 months)      | ~$1.00 / 1M requests                |
| SES              | 62,000 emails/month (from Lambda)    | ~$0.10 / 1,000 emails               |
| CloudWatch Logs  | 5 GB ingestion / month               | ~$0.50 / GB ingested                |
| WAF (optional)   | None                                 | ~$5.00/month WebACL + $1/M requests |

For a typical contact form (hundreds of submissions/month), the effective cost is **$0/month** within free tier limits.

---

## Tear-Down

Remove all provisioned AWS resources:

```bash
cd terraform
terraform destroy
```

> The Lambda zip artifact (`lambda.zip`) created in the project root is local only and can be deleted manually after destroy.

---

## Customization Suggestions

| Goal                              | How to implement                                                                     |
|-----------------------------------|--------------------------------------------------------------------------------------|
| Add reCAPTCHA v3                  | Verify token server-side in Lambda before calling SES                                |
| Store submissions in DynamoDB     | Add `dynamodb:PutItem` to the IAM policy; write item before `SendEmail`              |
| Send auto-reply to the submitter  | Call `SendEmail` a second time with `TO_EMAIL = event email`, `FROM_EMAIL` as sender |
| Use a custom domain               | Add API Gateway custom domain name + ACM certificate resources in Terraform          |
| Enable SES production access      | Follow AWS docs to lift sandbox restrictions and send to unverified addresses        |
| Restrict to specific country      | Add WAFv2 geo-match rule in `aws_wafv2_web_acl` alongside the rate limit rule        |
| Slack / webhook notification      | Call `fetch` to a Slack incoming webhook URL at the end of the Lambda handler        |
| Host frontend on S3 + CloudFront  | Add `aws_s3_bucket`, `aws_cloudfront_distribution` Terraform resources               |