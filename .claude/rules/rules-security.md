---
paths:
  - "**"
---

# Security Rules (Universal)

## No Hardcoded Credentials — CRITICAL
- NEVER hardcode API keys, tokens, passwords, or secrets in source code
- NEVER commit `.env` files
- Use environment variables for all secrets

## NEVER
- Never expose stack traces or internal errors to users
- Never log sensitive data (passwords, tokens, PII)
- Never use `eval()` or `new Function()`
- Never trust `X-Forwarded-For` headers without validation
