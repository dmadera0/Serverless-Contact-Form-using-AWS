'use strict';

const { SESClient, SendEmailCommand } = require('@aws-sdk/client-ses');

const ses = new SESClient({ region: process.env.AWS_REGION || 'us-east-1' });

const TO_EMAIL       = process.env.TO_EMAIL;
const FROM_EMAIL     = process.env.FROM_EMAIL;
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || '*')
  .split(',')
  .map(o => o.trim())
  .filter(Boolean);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getCorsHeaders(requestOrigin) {
  let allowOrigin = '*';
  if (ALLOWED_ORIGINS.length && !ALLOWED_ORIGINS.includes('*')) {
    allowOrigin = ALLOWED_ORIGINS.includes(requestOrigin) ? requestOrigin : ALLOWED_ORIGINS[0];
  }
  return {
    'Access-Control-Allow-Origin':  allowOrigin,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age':       '300',
  };
}

function respond(statusCode, body, corsHeaders) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
    body: JSON.stringify(body),
  };
}

function stripHtml(str) {
  return String(str).replace(/<[^>]*>/g, '').trim();
}

function truncate(str, max) {
  return str.slice(0, max);
}

function sanitize(raw, maxLen) {
  return truncate(stripHtml(raw ?? ''), maxLen);
}

function isValidEmail(email) {
  // RFC 5322-ish, practical regex
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email);
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

function validate({ name, email, subject, message }) {
  const errors = [];

  if (name.length < 2)          errors.push({ field: 'name',    message: 'Name must be at least 2 characters.' });
  if (!isValidEmail(email))     errors.push({ field: 'email',   message: 'Please enter a valid email address.' });
  if (subject.length < 3)       errors.push({ field: 'subject', message: 'Subject must be at least 3 characters.' });
  if (message.length < 10)      errors.push({ field: 'message', message: 'Message must be at least 10 characters.' });

  return errors;
}

// ---------------------------------------------------------------------------
// Email building
// ---------------------------------------------------------------------------

function buildHtmlEmail({ name, email, phone, subject, message }) {
  const phoneRow = phone
    ? `<tr>
        <td style="padding:8px 0;font-family:'DM Mono',Courier,monospace;font-size:13px;color:#888;text-transform:uppercase;letter-spacing:.05em;width:90px;vertical-align:top;">Phone</td>
        <td style="padding:8px 0;font-size:15px;color:#222;">${escHtml(phone)}</td>
       </tr>`
    : '';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>New Contact Form Submission</title>
</head>
<body style="margin:0;padding:0;background:#f5f5f5;font-family:Georgia,'Times New Roman',serif;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f5;padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#fff;border-radius:4px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.08);">

        <!-- Header -->
        <tr>
          <td style="background:#1a1a1a;padding:32px 40px;">
            <p style="margin:0;font-family:'DM Mono',Courier,monospace;font-size:11px;color:#c9a84c;text-transform:uppercase;letter-spacing:.12em;">New Message</p>
            <h1 style="margin:8px 0 0;font-size:24px;color:#fff;font-weight:400;letter-spacing:.02em;">Contact Form Submission</h1>
          </td>
        </tr>

        <!-- Gold accent bar -->
        <tr><td style="height:3px;background:linear-gradient(90deg,#c9a84c,#e8d5a3);"></td></tr>

        <!-- Body -->
        <tr>
          <td style="padding:36px 40px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
              <tr>
                <td style="padding:8px 0;font-family:'DM Mono',Courier,monospace;font-size:13px;color:#888;text-transform:uppercase;letter-spacing:.05em;width:90px;vertical-align:top;">Name</td>
                <td style="padding:8px 0;font-size:15px;color:#222;">${escHtml(name)}</td>
              </tr>
              <tr>
                <td style="padding:8px 0;font-family:'DM Mono',Courier,monospace;font-size:13px;color:#888;text-transform:uppercase;letter-spacing:.05em;vertical-align:top;">Email</td>
                <td style="padding:8px 0;font-size:15px;color:#222;"><a href="mailto:${escHtml(email)}" style="color:#c9a84c;text-decoration:none;">${escHtml(email)}</a></td>
              </tr>
              ${phoneRow}
              <tr>
                <td style="padding:8px 0;font-family:'DM Mono',Courier,monospace;font-size:13px;color:#888;text-transform:uppercase;letter-spacing:.05em;vertical-align:top;">Subject</td>
                <td style="padding:8px 0;font-size:15px;color:#222;">${escHtml(subject)}</td>
              </tr>
              <tr>
                <td colspan="2" style="padding-top:24px;">
                  <p style="margin:0 0 8px;font-family:'DM Mono',Courier,monospace;font-size:13px;color:#888;text-transform:uppercase;letter-spacing:.05em;">Message</p>
                  <div style="background:#fafafa;border-left:3px solid #c9a84c;padding:16px 20px;font-size:15px;color:#333;line-height:1.7;white-space:pre-wrap;">${escHtml(message)}</div>
                </td>
              </tr>
            </table>
          </td>
        </tr>

        <!-- Footer -->
        <tr>
          <td style="background:#f9f9f9;border-top:1px solid #eee;padding:20px 40px;">
            <p style="margin:0;font-family:'DM Mono',Courier,monospace;font-size:11px;color:#aaa;">
              Sent via contact form &bull; ${new Date().toUTCString()}
            </p>
          </td>
        </tr>

      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

function buildTextEmail({ name, email, phone, subject, message }) {
  const phoneLine = phone ? `Phone:   ${phone}\n` : '';
  return [
    'New Contact Form Submission',
    '===========================',
    '',
    `Name:    ${name}`,
    `Email:   ${email}`,
    phoneLine.trimEnd(),
    `Subject: ${subject}`,
    '',
    'Message:',
    message,
    '',
    `Sent: ${new Date().toUTCString()}`,
  ].filter(line => line !== undefined).join('\n');
}

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

exports.handler = async (event) => {
  const origin = event.headers?.origin || event.headers?.Origin || '';
  const corsHeaders = getCorsHeaders(origin);

  // CORS preflight
  if (event.requestContext?.http?.method === 'OPTIONS' || event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: corsHeaders, body: '' };
  }

  // Method guard
  const method = event.requestContext?.http?.method || event.httpMethod || '';
  if (method !== 'POST') {
    return respond(405, { success: false, error: 'Method not allowed.' }, corsHeaders);
  }

  // Parse body
  let raw;
  try {
    raw = JSON.parse(event.body || '{}');
  } catch {
    return respond(400, { success: false, error: 'Invalid JSON body.' }, corsHeaders);
  }

  // Sanitize
  const name    = sanitize(raw.name,    100);
  const email   = sanitize(raw.email,   254);
  const subject = sanitize(raw.subject, 200);
  const message = sanitize(raw.message, 5000);
  const phone   = sanitize(raw.phone,   20);

  // Validate
  const errors = validate({ name, email, subject, message });
  if (errors.length) {
    return respond(422, { success: false, errors }, corsHeaders);
  }

  // Send email
  const params = {
    Source: FROM_EMAIL,
    Destination: { ToAddresses: [TO_EMAIL] },
    ReplyToAddresses: [email],
    Message: {
      Subject: { Data: `[Contact Form] ${subject}`, Charset: 'UTF-8' },
      Body: {
        Html: { Data: buildHtmlEmail({ name, email, phone, subject, message }), Charset: 'UTF-8' },
        Text: { Data: buildTextEmail({ name, email, phone, subject, message }), Charset: 'UTF-8' },
      },
    },
  };

  try {
    await ses.send(new SendEmailCommand(params));

    console.log(JSON.stringify({
      event: 'contact_form_submitted',
      name,
      email,
      subject,
      timestamp: new Date().toISOString(),
    }));

    return respond(200, {
      success: true,
      message: 'Your message has been sent successfully. We\'ll be in touch soon.',
    }, corsHeaders);

  } catch (err) {
    console.error(JSON.stringify({
      event: 'ses_send_error',
      error: err.message,
      code:  err.name,
      stack: err.stack,
    }));

    return respond(500, {
      success: false,
      error: 'Failed to send your message. Please try again later.',
    }, corsHeaders);
  }
};
