# Supernova CLI

The `supernova` CLI manages the Supernova installation.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/supernova -o supernova
chmod +x supernova
./supernova install
```

## Commands

| Command | Description |
|---------|-------------|
| `./supernova install` | Download and install the binary |
| `./supernova configure` | Run the configuration wizard |
| `./supernova start` | Start the service |
| `./supernova stop` | Stop the service |
| `./supernova restart` | Restart the service |
| `./supernova status` | Show service status |
| `./supernova logs` | Show recent logs |
| `./supernova logs -f` | Follow logs in real-time |
| `./supernova update` | Update to latest version |
| `./supernova uninstall` | Remove installation |
| `./supernova doctor` | Check system requirements |
| `./supernova help` | Show help |

## Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SN_USER_DIR` | Installation directory | `~/.local/supernova` |
| `SN_CONFIG_DIR` | Config directory | `~/.config/supernova` |

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

## Development

For local development without the CLI:

```bash
gleam deps download
gleam run -m supernova/wizard_main
gleam run
```
