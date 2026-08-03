# Security Considerations

This document outlines security features and considerations for the `mail-mcp` MCP server.

## TLS Enforcement

All IMAP connections require TLS encryption by default. Insecure connections are rejected.

### Configuration

```bash
# Per-account (default: true)
MAIL_IMAP_<ACCOUNT>_SECURE=true

# Common IMAP TLS ports
MAIL_IMAP_<ACCOUNT>_PORT=993   # IMAPS (implicit TLS)
```

### Behavior

- TLS certificate verification is enforced
- Hostname verification is performed
- Connection failures occur if certificates cannot be validated
- STARTTLS is not supported; use implicit TLS (IMAPS) on port 993

## Password Secrecy

Passwords are handled with strict secrecy guarantees:

### Storage

- Passwords are stored using Rust's `SecretString` type
- Passwords are never included in log output
- Passwords are never returned in tool responses

### Environment Variables

```bash
# Password in environment (never logged)
MAIL_IMAP_DEFAULT_PASS=your-app-password
```

### Best Practices

- Use app-specific passwords instead of account passwords when available
- Never commit `.env` files to version control
- Use secure credential managers for production deployments
- Rotate credentials periodically

## Write Operation Gating

Destructive operations are disabled by default and require explicit opt-in.

### Enabling Write Operations

```bash
MAIL_IMAP_WRITE_ENABLED=true
```

### Affected Tools

When `MAIL_IMAP_WRITE_ENABLED=false`, these tools return errors:
- `imap_update_message_flags` - Add/remove flags
- `imap_copy_message` - Copy messages
- `imap_move_message` - Move messages
- `imap_delete_message` - Delete messages

### Delete Confirmation

`imap_delete_message` requires explicit confirmation regardless of write gating:

```json
{
  "account_id": "default",
  "message_id": "imap:default:INBOX:12345:42",
  "confirm": true  // Required literal true
}
```

## Send Operation Gating

All outgoing-mail tools — SMTP (`smtp_send_message`, `smtp_reply_message`,
`smtp_forward_message`), EWS (`ews_send_message`), and Microsoft Graph
(`graph_send_message`) — are disabled unless `MAIL_SMTP_WRITE_ENABLED=true`.
The gate is enforced server-side at the top of each send handler, so no send
path (including Graph) can transmit mail while the switch is off.

```bash
MAIL_SMTP_WRITE_ENABLED=true
```

## HTTP Transport Authentication

Over stdio the server is spawned by its MCP client and inherits that trust
boundary. Over `MAIL_MCP_TRANSPORT=http` it is a network listener, and anything
able to reach the socket can drive the mailbox. Set `MAIL_MCP_AUTH_TOKEN` to
require a bearer token on every request:

```bash
MAIL_MCP_TRANSPORT=http
MAIL_MCP_AUTH_TOKEN=<a long random string>
```

Requests must then carry `Authorization: Bearer <token>`. The scheme is matched
case-insensitively; the token is compared in constant time, so a caller cannot
recover it byte by byte from response timing. A request that fails the check is
answered with `401` and a `WWW-Authenticate: Bearer` challenge **before it
reaches the MCP service** — no session is opened, no IMAP connection is made,
and the response carries nothing about the server's configuration.

When the variable is unset the endpoint stays open to anyone who can reach it,
which is only appropriate when the socket itself is the boundary (loopback, or
a private container network with no published port). Startup logs a warning in
that case. Network isolation and a token are complementary: the token is what
still holds if something else lands on that network.

## Attachment Path Restrictions

Outgoing-mail tools accept attachments either inline (`content_base64`) or by
local `file_path`. To stop a prompt-injected model from reading and
exfiltrating arbitrary local files (for example `~/.ssh/id_rsa`, `/etc/passwd`,
or the server's own `.env`), `file_path` reads are confined to an allowlist:

- `MAIL_ATTACHMENT_ALLOWED_DIRS` — a `:`-separated list of directories from
  which attachments may be read, and under which a caller-supplied download
  `output_dir` must fall. Paths are canonicalized (resolving symlinks and
  rejecting `..`) before the containment check, so neither traversal nor a
  symlink planted inside an allowed directory can escape it.
- When unset, the allowlist defaults to a single entry: the configured
  `MAIL_ATTACHMENT_DOWNLOAD_DIR`, or the system temp directory if that is also
  unset. This keeps the common "download an attachment, then re-attach it to a
  reply" workflow working while denying arbitrary reads by default.
- `MAIL_ATTACHMENT_MAX_BYTES` (default 25 MB) caps the total size of all
  attachments on a single outgoing message, and no more than 50 attachments may
  be sent per message. Sizes are checked from filesystem metadata before the
  file is read into memory.

## MIME Depth Bounding

Inbound messages are parsed recursively. To prevent a maliciously deep
multipart tree from overflowing the stack (a remote denial of service), MIME
traversal is capped at 100 levels of nesting; messages exceeding the cap are
rejected rather than parsed. PDF text extraction (opt-in, ≤ 5 MB) is additionally
run inside a panic boundary so a malformed PDF cannot abort the request.

## Output Bounding

All potentially large outputs are bounded to prevent resource exhaustion.

### Body Text

```json
{
  "body_max_chars": 2000  // Range: 100..20000, default: 2000
}
```

### HTML Output

- HTML is sanitized using `ammonia` before return
- Potentially dangerous tags and attributes are stripped
- CSS styles are removed
- JavaScript is completely removed

### Attachment Text Extraction

```json
{
  "extract_attachment_text": true,
  "attachment_text_max_chars": 10000  // Range: 100..50000, default: 10000
}
```

### Raw Message Source

```json
{
  "max_bytes": 200000  // Range: 1024..1000000, default: 200000
}
```

### Attachment Size Limits

PDF text extraction is limited to attachments ≤ 5MB. Larger attachments are skipped but do not fail the tool call.

## Input Validation

All inputs are validated before IMAP operations:

### Length Bounds

- `query`, `from`, `to`, `subject`: 1..256 characters
- `account_id`: 1..64 characters, pattern `^[A-Za-z0-9_-]+$`
- `mailbox`: 1..256 characters
- `limit`: 1..50 messages

### Content Sanitization

- Search text fields must not contain ASCII control characters
- Mailbox names must not contain ASCII control characters

### Search Result Limits

Searches matching more than 20,000 messages are rejected:

```
Error: invalid input: search matched 25000 messages; narrow filters to at most 20000 results
```

Resolution: Add tighter filters (`last_days`, `from`, `subject`, date ranges).

## Timeout Protection

All network operations have configurable timeouts:

```bash
# Connection establishment
MAIL_IMAP_CONNECT_TIMEOUT_MS=30000      # 30 seconds

# Server greeting
MAIL_IMAP_GREETING_TIMEOUT_MS=15000     # 15 seconds

# Socket operations (idle, read, write)
MAIL_IMAP_SOCKET_TIMEOUT_MS=300000     # 5 minutes
```

Timeouts prevent indefinite hanging and ensure the server remains responsive.

## Logging and Auditing

### Log Redaction

- Passwords are never logged
- Secret-like keys (`*_PASS`, `*_TOKEN`, `*_KEY`) are redacted in logs
- Message bodies and attachments are not logged

### Response Metadata

All tool responses include metadata for auditing:

```json
{
  "meta": {
    "now_utc": "2024-02-26T10:30:45.123Z",
    "duration_ms": 245
  }
}
```

## Security Best Practices

### For End Users

1. **Use app passwords**: For Gmail, Outlook, and other services, use app-specific passwords rather than account passwords
2. **Enable 2FA**: Require two-factor authentication on email accounts
3. **Review access logs**: Periodically review email account access logs for suspicious activity
4. **Restrict write access**: Keep `MAIL_IMAP_WRITE_ENABLED=false` unless needed
5. **Secure .env files**: Ensure `.env` files have restrictive permissions (`chmod 600 .env`)

### For Operators

1. **Principle of least privilege**: Run the server with minimal required permissions
2. **Network isolation**: Deploy in isolated network segments where possible
3. **Regular updates**: Keep dependencies and the server updated
4. **Audit logs**: Monitor server logs for unusual patterns or errors
5. **Rate limiting**: Consider implementing additional rate limiting at the infrastructure layer

### For Development

1. **Security review**: Changes to security-sensitive code should be reviewed
2. **Dependency auditing**: Regularly audit dependencies for vulnerabilities
3. **Test boundaries**: Test input validation and output bounding thoroughly
4. **Secret management**: Never hardcode credentials in code or tests

## Known Limitations

1. **No STARTTLS support**: Only implicit TLS (IMAPS) is supported
2. **No certificate pinning**: Certificates are validated per standard PKI; custom CA chains are not supported
3. **No client authentication**: Client certificates are not supported
4. **No encryption at rest**: Credentials are in memory only; disk encryption is the user's responsibility
