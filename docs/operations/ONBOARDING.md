# Onboarding (Supernova)

Quick guide to getting started with Supernova.

## Quickstart

```bash
# Download the CLI
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/supernova -o supernova
chmod +x supernova

# Install, configure, and start
./supernova install
./supernova configure
./supernova start
```

That's it. No root access required.

## Managing the service

```bash
./supernova status   # Check if running
./supernova logs     # View logs
./supernova stop     # Stop the service
./supernova restart  # Restart
```

## Troubleshooting

- `command not found: supernova`: Make sure `~/.local/bin` is in your PATH, or run with `./supernova`
- No response from channels: Check logs with `./supernova logs`
- Configuration issues: Run `./supernova configure` again

## Docker (development only)

For local development with Docker, see [DOCKER.md](DOCKER.md).
