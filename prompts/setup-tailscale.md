You are configuring Tailscale on an Ubuntu 24.04 VM that already has OpenClaw Gateway installed and running. You are the `openclaw` user with sudo access.

Your job is to install Tailscale, start it, and help the user authenticate so they can access this VM securely from anywhere.

---

## STEP 1: Install Tailscale

Run the official Tailscale installation script:

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
```

Verify the installation:

```bash
tailscale version
```

Should show the Tailscale version number.

---

## STEP 2: Start Tailscale and Get Auth URL

Start Tailscale in the background. This will output an authentication URL that the user needs to visit:

```bash
sudo tailscale up
```

**IMPORTANT**: The `tailscale up` command will print a URL like:
```
To authenticate, visit:
  https://login.tailscale.com/a/xxxxxxxxxxxxx
```

**Capture and display this URL prominently** so the user can click it to authenticate their device to their Tailnet.

---

## STEP 3: Wait for Authentication

After the user visits the URL and authenticates, poll the status to confirm:

```bash
# Check status every 5 seconds
while ! tailscale status | grep -q "100\."; do
  echo "Waiting for Tailscale authentication... (check the URL above)"
  sleep 5
done

echo "✓ Tailscale authenticated successfully!"
```

Get the Tailscale IP address:

```bash
TAILSCALE_IP=$(tailscale ip -4)
echo "Tailscale IP: $TAILSCALE_IP"
```

---

## STEP 4: Configure Tailscale Access for OpenClaw

Since OpenClaw Gateway binds to loopback (127.0.0.1:18789), users can access it via SSH tunnel:

```bash
# From your laptop (on the same Tailnet):
ssh -N -L 18789:127.0.0.1:18789 openclaw@$TAILSCALE_IP
# Then open: http://localhost:18789/openclaw
```

**Optional**: If the `tailscale serve` command is available, you can expose the gateway directly:

```bash
# This creates an HTTPS endpoint for the gateway (if supported)
sudo tailscale serve --bg 18789
```

Check if this worked:

```bash
tailscale status
```

Should show the serve configuration if it succeeded.

---

## STEP 5: Verification

Run these checks and report the results:

1. `tailscale status` — should show "Connected" or similar, and list the Tailscale IP
2. `tailscale ip -4` — should return the Tailscale IPv4 address (100.x.x.x)
3. `ping -c 1 $(tailscale ip -4)` — should successfully ping itself

---

## FINAL OUTPUT

Print a summary for the user:

```
✓ Tailscale installed and authenticated successfully!

Tailscale IP: 100.x.x.x

Access OpenClaw Gateway from any device on your Tailnet:

  1. SSH access:
     ssh openclaw@100.x.x.x

  2. Access the gateway via SSH tunnel:
     ssh -N -L 18789:127.0.0.1:18789 openclaw@100.x.x.x
     Then open: http://localhost:18789/openclaw

  3. Direct SSH for debugging:
     ssh openclaw@100.x.x.x
     openclaw gateway status
```

If authentication times out or fails, provide clear error messages and instructions for manual retry.
