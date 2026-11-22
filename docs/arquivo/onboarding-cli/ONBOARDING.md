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

Requirements: Docker installed and running.

## Managing the service

```bash
./supernova status   # Check if running
./supernova logs     # View logs
./supernova stop     # Stop the service
./supernova restart  # Restart
```

## Troubleshooting

- Docker required: Install Docker from https://docker.com
- No response from channels: Check logs with `./supernova logs`
- Configuration issues: Run `./supernova configure` again
