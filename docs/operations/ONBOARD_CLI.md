# Supernova CLI

The `supernova` CLI manages the Supernova installation via Docker.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/supernova -o supernova
chmod +x supernova
./supernova install
```

## Commands

| Command | Description |
|---------|-------------|
| `./supernova install` | Pull Docker image |
| `./supernova configure` | Run wizard (via Docker) |
| `./supernova enable` | Show auto-start setup |
| `./supernova start` | Start service (via Docker) |
| `./supernova stop` | Stop service |
| `./supernova restart` | Restart service |
| `./supernova status` | Show service status |
| `./supernova logs` | Show recent logs |
| `./supernova logs -f` | Follow logs in real-time |
| `./supernova update` | Update to latest version |
| `./supernova doctor` | Check system requirements |
| `./supernova help` | Show help |

## Environment variables

Set these in `~/.config/supernova/secrets.env`:

```bash
SUPERNOVA_ANTHROPIC_API_KEY=your_key
SUPERNOVA_DISCORD_TOKEN=your_token
# etc.
```

## Examples

```bash
# First time setup
./supernova install
./supernova configure
./supernova start

# Check status
./supernova status
./supernova logs

# Update
./supernova update
./supernova restart
```

## Requirements

- Docker installed and running
- No root access required
