# OpenClaw Configuration Templates

This directory contains base configuration templates used by the deployment scripts.

## openclaw.json

Base OpenClaw Gateway configuration template with secure defaults.

### Key Features

**Gateway Binding:**
- `bind: "loopback"` - Gateway only listens on 127.0.0.1 (not exposed to public internet)
- `port: 18789` - Default OpenClaw gateway port
- `auth.mode: "token"` - Token-based authentication required for all API calls

**Telegram Channel:**
- `enabled: true` - Telegram bot integration enabled by default
- `dmPolicy: "pairing"` - Requires pairing code approval for new DM conversations
- Token must be replaced with actual bot token from @BotFather

**HTTP Endpoints:**
- `chatCompletions.enabled: true` - Enables OpenAI-compatible chat completions endpoint
- Accessible at `http://localhost:18789/v1/chat/completions`

**Security:**
- `logging.redactSensitive: true` - Automatically redacts API keys and tokens from logs
- Gateway bound to loopback prevents public internet access
- Token auth required for all API operations

**Skills:**
- `openai-whisper-api` - Disabled by default, enabled by setup-skills.sh when OpenAI key is provided

### Usage

This template is copied to the VM during deployment and customized by:
- Claude Code (via prompts/setup-openclaw.md)
- setup-skills.sh (adds OpenAI API key if provided)

The deployed configuration is stored at: `/home/openclaw/.openclaw/openclaw.json`

### Customization

To add custom configuration:
1. Modify this template
2. Redeploy instances (or manually update existing instances)
3. Restart gateway: `openclaw gateway restart`

### Security Notes

⚠️ **Never commit real credentials to this template**
- Use placeholder values only
- Real credentials are injected during deployment
- All sensitive data is redacted from logs when `redactSensitive: true`
