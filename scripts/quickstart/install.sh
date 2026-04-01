#!/bin/bash
#
# Supernova Quickstart Installer
# ==============================
# Installs Supernova on Linux with systemd.
#
# Usage:
#   Interactive:   curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | bash
#   Non-interactive: curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | bash -s -- [options]
#
# Options:
#   --non-interactive     Run without prompting (for CI/automation)
#   --provider NAME       LLM provider (anthropic, openai, openrouter, etc.)
#   --model NAME          Model name
#   --api-key KEY         API key for the provider
#   --channels LIST       Comma-separated list of channels (discord,telegram,slack)
#   --db-host HOST        Database host (default: localhost)
#   --db-port PORT        Database port (default: 5432)
#   --db-name NAME        Database name (default: supernova)
#   --db-user NAME        Database user (default: supernova)
#   --db-password PASSWORD Database password
#   --skip-postgres       Skip PostgreSQL installation
#   --skip-wizard         Skip wizard (use provided config only)
#   --force               Overwrite existing config
#   --version VERSION     Specific release version to install
#   --help                Show this help

set -e

# Configuration
readonly SUPERNOVA_VERSION="0.2.0"
readonly SUPERNOVA_USER="supernova"
readonly SUPERNOVA_GROUP="supernova"
readonly SUPERNOVA_HOME="/var/lib/supernova"
readonly SUPERNOVA_CONFIG_DIR="/etc/supernova"
readonly SUPERNOVA_CONFIG_FILE="${SUPERNOVA_CONFIG_DIR}/supernova.yaml"
readonly SUPERNOVA_SECRETS_FILE="${SUPERNOVA_CONFIG_DIR}/secrets.env"
readonly SUPERNOVA_BINARY_DIR="/usr/local/bin"
readonly SUPERNOVA_BINARY="${SUPERNOVA_BINARY_DIR}/supernova"
readonly SUPERNOVA_UNIT_FILE="/etc/systemd/system/supernova.service"
readonly SUPERNOVA_INSTALLER_VERSION="1.0.0"

# Defaults
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="supernova"
DB_USER="supernova"
DB_PASSWORD=""
NON_INTERACTIVE=false
SKIP_POSTGRES=false
SKIP_WIZARD=false
FORCE=false
PROVIDER=""
MODEL=""
API_KEY=""
CHANNELS=""
VERSION=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Show help
show_help() {
    grep "^#" "$0" | sed 's/^# //; s/^#//' | head -30
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --provider)
                PROVIDER="$2"
                shift 2
                ;;
            --model)
                MODEL="$2"
                shift 2
                ;;
            --api-key)
                API_KEY="$2"
                shift 2
                ;;
            --channels)
                CHANNELS="$2"
                shift 2
                ;;
            --db-host)
                DB_HOST="$2"
                shift 2
                ;;
            --db-port)
                DB_PORT="$2"
                shift 2
                ;;
            --db-name)
                DB_NAME="$2"
                shift 2
                ;;
            --db-user)
                DB_USER="$2"
                shift 2
                ;;
            --db-password)
                DB_PASSWORD="$2"
                shift 2
                ;;
            --skip-postgres)
                SKIP_POSTGRES=true
                shift
                ;;
            --skip-wizard)
                SKIP_WIZARD=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -s|--)
                shift
                break
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Check if running as root and detect install method
check_root() {
    if [[ $EUID -ne 0 ]]; then
        # Detect if script was piped (insecure to run as root)
        if [[ ! -t 0 ]]; then
            log_error "ERROR: Piping this script is insecure."
            echo ""
            echo "Download the script first, then run with sudo:"
            echo ""
            echo "    curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh -o install.sh"
            echo "    chmod +x install.sh"
            echo "    sudo ./install.sh"
            echo ""
            exit 1
        fi
        log_error "This installer must be run as root"
        echo ""
        echo "Run with: sudo $0"
        echo ""
        exit 1
    fi
}

# Detect system information
detect_system() {
    log_info "Detecting system..."

    # Detect distribution
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO="$ID"
        DISTRO_VERSION="$VERSION_ID"
        DISTRO_NAME="$NAME"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO=$(cat /etc/redhat-release | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
        DISTRO_NAME="$DISTRO"
        DISTRO_VERSION=""
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        DISTRO_NAME="Debian"
        DISTRO_VERSION=$(cat /etc/debian_version)
    else
        DISTRO="unknown"
        DISTRO_NAME="Unknown Linux"
        DISTRO_VERSION=""
    fi

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armhf"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    # Detect package manager
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
    else
        PKG_MANAGER="unknown"
    fi

    # Check for systemd
    if ! command -v systemctl &> /dev/null || [[ ! -d /run/systemd/system ]]; then
        log_error "systemd is required for this installer"
        exit 1
    fi

    log_success "System detected: $DISTRO_NAME ($DISTRO $DISTRO_VERSION), $ARCH, $PKG_MANAGER"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_cmds=()

    # curl is required for downloading
    if ! command -v curl &> /dev/null; then
        missing_cmds+=("curl")
    fi

    if ! command -v tar &> /dev/null; then
        missing_cmds+=("tar")
    fi

    if ! command -v systemctl &> /dev/null; then
        missing_cmds+=("systemctl")
    fi

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_cmds[*]}"
        log_info "Install them with: sudo $PKG_MANAGER install ${missing_cmds[*]}"
        exit 1
    fi

    log_success "All prerequisites satisfied"
}

# Get the version to install
get_version() {
    if [[ -n "$VERSION" ]]; then
        log_info "Using specified version: $VERSION"
        return
    fi

    log_info "Fetching latest version..."
    VERSION=$(curl -fsSL "https://api.github.com/repos/manelsen/supernova/releases/latest" 2>/dev/null | \
        grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//') || VERSION="$SUPERNOVA_VERSION"

    log_info "Latest version: $VERSION"
}

# Try to download a pre-built release
download_release() {
    log_info "Checking for pre-built release..."

    local download_url="https://github.com/manelsen/supernova/releases/download/v${VERSION}/supernova-${VERSION}-linux-${ARCH}.tar.gz"

    log_info "Attempting: $download_url"

    if curl -fsSL --connect-timeout 10 -o /tmp/supernova.tar.gz "$download_url"; then
        log_success "Downloaded pre-built release"
        extract_release
        return 0
    fi

    log_warn "No pre-built release available for $ARCH"
    return 1
}

# Extract the downloaded release
extract_release() {
    log_info "Extracting release..."
    tar -xzf /tmp/supernova.tar.gz -C /tmp
    local extracted_dir=$(tar -tzf /tmp/supernova.tar.gz | head -1 | cut -f1 -d"/")

    if [[ -f "/tmp/${extracted_dir}/supernova" ]]; then
        install_binary "/tmp/${extracted_dir}/supernova"
        rm -rf "/tmp/supernova.tar.gz" "/tmp/${extracted_dir}"
        log_success "Installed from pre-built release"
    else
        log_error "Release archive format unexpected"
        return 1
    fi
}

# Install from source
install_from_source() {
    log_info "Installing from source (fallback)..."

    if ! command -v gleam &> /dev/null; then
        log_info "Gleam not found. Installing Gleam..."
        install_gleam
    fi

    if ! command -v erl &> /dev/null; then
        log_error "Erlang/OTP is required for building from source"
        log_info "Install Erlang: sudo $PKG_MANAGER install erlang"
        exit 1
    fi

    # Check if we're in the right directory
    if [[ ! -f "gleam.toml" ]]; then
        log_error "gleam.toml not found. Run this installer from the Supernova source directory."
        exit 1
    fi

    log_info "Building Supernova (this may take several minutes)..."
    if ! gleam build --release 2>&1; then
        log_error "Build failed"
        exit 1
    fi

    # Find the built binary
    local built_binary=$(find ./build/release -name "supernova" -type f 2>/dev/null | head -1)
    if [[ -z "$built_binary" ]]; then
        log_error "Build succeeded but binary not found"
        exit 1
    fi

    install_binary "$built_binary"
    log_success "Installed from source"
}

# Install Gleam
install_gleam() {
    log_info "Installing Gleam..."

    local gleam_url="https://github.com/gleam-lang/gleam/releases/latest/download/gleam-linux-${ARCH}-unknown-eglibc.tar.gz"

    if curl -fsSL --connect-timeout 10 -o /tmp/gleam.tar.gz "$gleam_url"; then
        tar -xzf /tmp/gleam.tar.gz -C /tmp
        if [[ -f /tmp/gleam ]]; then
            mv /tmp/gleam /usr/local/bin/gleam
            chmod +x /usr/local/bin/gleam
            rm -f /tmp/gleam.tar.gz
            log_success "Gleam installed"
        fi
    else
        log_error "Failed to download Gleam"
        exit 1
    fi
}

# Install the binary
install_binary() {
    local binary_path="$1"

    log_info "Installing binary to $SUPERNOVA_BINARY..."

    mkdir -p "$SUPERNOVA_BINARY_DIR"
    cp "$binary_path" "$SUPERNOVA_BINARY"
    chmod +x "$SUPERNOVA_BINARY"

    # Verify binary works
    if ! "$SUPERNOVA_BINARY" --version &> /dev/null; then
        log_warn "Binary may not be compatible. Continuing anyway..."
    fi
}

# Create supernova user and group
create_user() {
    log_info "Creating system user and group..."

    if getent group "$SUPERNOVA_GROUP" &> /dev/null; then
        log_info "Group '$SUPERNOVA_GROUP' already exists"
    else
        groupadd --system "$SUPERNOVA_GROUP"
        log_success "Created group '$SUPERNOVA_GROUP'"
    fi

    if getent passwd "$SUPERNOVA_USER" &> /dev/null; then
        log_info "User '$SUPERNOVA_USER' already exists"
    else
        useradd --system \
            --gid "$SUPERNOVA_GROUP" \
            --home-dir "$SUPERNOVA_HOME" \
            --shell /usr/sbin/nologin \
            --comment "Supernova AI OS" \
            "$SUPERNOVA_USER"
        log_success "Created user '$SUPERNOVA_USER'"
    fi
}

# Create directories
create_directories() {
    log_info "Creating directories..."

    mkdir -p "$SUPERNOVA_CONFIG_DIR"
    mkdir -p "$SUPERNOVA_HOME"
    mkdir -p "$SUPERNOVA_HOME/data"

    # Set permissions
    chown -R "$SUPERNOVA_USER:$SUPERNOVA_GROUP" "$SUPERNOVA_HOME"
    chmod 755 "$SUPERNOVA_CONFIG_DIR"

    log_success "Directories created with correct permissions"
}

# Install and configure PostgreSQL
setup_postgres() {
    if [[ "$SKIP_POSTGRES" == "true" ]]; then
        log_info "Skipping PostgreSQL installation (--skip-postgres)"
        return
    fi

    log_info "Setting up PostgreSQL..."

    # Check if PostgreSQL is already running
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" &> /dev/null; then
        log_success "PostgreSQL is already running"
        setup_database
        return
    fi

    # Detect OS and install PostgreSQL
    case "$DISTRO" in
        ubuntu|debian)
            install_postgres_apt
            ;;
        fedora|rhel|centos|rocky|almalinux)
            install_postgres_dnf
            ;;
        arch)
            install_postgres_pacman
            ;;
        opensuse|sles)
            install_postgres_zypper
            ;;
        *)
            log_warn "Unsupported distro for auto-install: $DISTRO"
            log_info "Please install PostgreSQL manually and re-run this installer"
            exit 1
            ;;
    esac

    setup_database
}

# Install PostgreSQL via apt
install_postgres_apt() {
    log_info "Installing PostgreSQL via apt..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq postgresql postgresql-client > /dev/null

    # Start PostgreSQL
    systemctl enable postgresql
    systemctl start postgresql

    # Wait for PostgreSQL to be ready
    for i in {1..30}; do
        if pg_isready &> /dev/null; then
            log_success "PostgreSQL installed and running"
            return 0
        fi
        sleep 1
    done

    log_error "PostgreSQL failed to start"
    exit 1
}

# Install PostgreSQL via dnf
install_postgres_dnf() {
    log_info "Installing PostgreSQL via dnf..."

    dnf install -y -q postgresql-server postgresql > /dev/null

    postgresql-setup --initdb > /dev/null 2>&1 || true
    systemctl enable postgresql
    systemctl start postgresql

    for i in {1..30}; do
        if pg_isready &> /dev/null; then
            log_success "PostgreSQL installed and running"
            return 0
        fi
        sleep 1
    done

    log_error "PostgreSQL failed to start"
    exit 1
}

# Install PostgreSQL via pacman
install_postgres_pacman() {
    log_info "Installing PostgreSQL via pacman..."

    pacman -Sy --noconfirm postgresql > /dev/null

    # Initialize database if needed
    if [[ ! -d /var/lib/postgres/data ]]; then
        sudo -u postgres initdb -D /var/lib/postgres/data > /dev/null 2>&1
    fi

    systemctl enable postgresql
    systemctl start postgresql

    for i in {1..30}; do
        if pg_isready &> /dev/null; then
            log_success "PostgreSQL installed and running"
            return 0
        fi
        sleep 1
    done

    log_error "PostgreSQL failed to start"
    exit 1
}

# Install PostgreSQL via zypper
install_postgres_zypper() {
    log_info "Installing PostgreSQL via zypper..."

    zypper install -y -q postgresql-server postgresql > /dev/null

    systemctl enable postgresql
    systemctl start postgresql

    for i in {1..30}; do
        if pg_isready &> /dev/null; then
            log_success "PostgreSQL installed and running"
            return 0
        fi
        sleep 1
    done

    log_error "PostgreSQL failed to start"
    exit 1
}

# Setup database user and database
setup_database() {
    log_info "Setting up database..."

    # Generate password if not provided
    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD=$(openssl rand -base64 24 2>/dev/null || head -c 32 /dev/urandom | base64)
    fi

    # Create role/user
    if ! su - postgres -s /bin/bash -c "psql -t -c \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" 2>/dev/null | grep -q 1; then
        su - postgres -s /bin/bash -c "psql -c \"CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';\"" 2>/dev/null
        log_success "Created database user"
    else
        log_info "Database user already exists"
    fi

    # Create database
    if ! su - postgres -s /bin/bash -c "psql -t -c \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" 2>/dev/null | grep -q 1; then
        su - postgres -s /bin/bash -c "psql -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\"" 2>/dev/null
        log_success "Created database"
    else
        log_info "Database already exists"
    fi

    # Grant privileges
    su - postgres -s /bin/bash -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};\"" 2>/dev/null

    # Run migrations
    run_migrations
}

# Run database migrations
run_migrations() {
    log_info "Running database migrations..."

    local migrations_dir="/var/lib/supernova/migrations"
    mkdir -p "$migrations_dir"

    # Copy migrations if they exist in the binary or source
    if [[ -f "/tmp/migrations/init.sql" ]]; then
        cp /tmp/migrations/init.sql "$migrations_dir/"
    elif [[ -d "./migrations" ]]; then
        cp -r ./migrations/* "$migrations_dir/" 2>/dev/null || true
    fi

    # Apply migrations
    if [[ -f "${migrations_dir}/init.sql" ]]; then
        su - postgres -s /bin/bash -c "psql -U postgres -d ${DB_NAME}" < "${migrations_dir}/init.sql" 2>/dev/null || true
        log_success "Migrations applied"
    else
        log_warn "No migrations found, database may need manual setup"
    fi
}

# Install systemd unit file
install_systemd_unit() {
    log_info "Installing systemd service unit..."

    cat > "$SUPERNOVA_UNIT_FILE" << EOF
[Unit]
Description=Supernova AI Operating System
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${SUPERNOVA_USER}
Group=${SUPERNOVA_GROUP}
WorkingDirectory=${SUPERNOVA_HOME}
EnvironmentFile=${SUPERNOVA_SECRETS_FILE}
ExecStart=${SUPERNOVA_BINARY} run
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=supernova

# Graceful shutdown
TimeoutStopSec=30
SendSIGTERM=yes

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SUPERNOVA_HOME}
Environment=HOME=${SUPERNOVA_HOME}

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SUPERNOVA_UNIT_FILE"
    systemctl daemon-reload

    log_success "Systemd unit installed"
}

# Generate configuration via wizard
run_wizard() {
    if [[ "$SKIP_WIZARD" == "true" ]]; then
        log_info "Skipping wizard (--skip-wizard)"
        generate_config_from_args
        return
    fi

    # Check if config already exists
    if [[ -f "$SUPERNOVA_CONFIG_FILE" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Configuration already exists at $SUPERNOVA_CONFIG_FILE"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing configuration"
            return
        fi
    fi

    log_info "Running configuration wizard..."

    # Build wizard command
    local wizard_cmd=("$SUPERNOVA_BINARY" run -m supernova/wizard_main)

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        # For non-interactive, pass args or use env vars
        if [[ -n "$PROVIDER" ]] && [[ -n "$MODEL" ]] && [[ -n "$API_KEY" ]]; then
            # Use non-interactive mode with provided args
            export SUPERNOVA_NON_INTERACTIVE=1
            export SUPERNOVA_PROVIDER="$PROVIDER"
            export SUPERNOVA_MODEL="$MODEL"
            export SUPERNOVA_API_KEY="$API_KEY"
            export SUPERNOVA_CHANNELS="$CHANNELS"
            export SUPERNOVA_DB_HOST="$DB_HOST"
            export SUPERNOVA_DB_PORT="$DB_PORT"
            export SUPERNOVA_DB_NAME="$DB_NAME"
            export SUPERNOVA_DB_USER="$DB_USER"
            export SUPERNOVA_DB_PASSWORD="$DB_PASSWORD"

            "${wizard_cmd[@]}" --non-interactive
        else
            log_error "Non-interactive mode requires: --provider, --model, --api-key"
            exit 1
        fi
    else
        "${wizard_cmd[@]}"
    fi

    if [[ ! -f "$SUPERNOVA_CONFIG_FILE" ]]; then
        log_error "Wizard did not generate configuration"
        exit 1
    fi

    log_success "Configuration generated"
}

# Generate config from command-line arguments (non-interactive fallback)
generate_config_from_args() {
    if [[ -z "$PROVIDER" ]] || [[ -z "$MODEL" ]]; then
        log_error "Config generation requires --provider and --model"
        exit 1
    fi

    log_info "Generating configuration from arguments..."

    # Create basic config
    cat > "$SUPERNOVA_CONFIG_FILE" << EOF
app_name: supernova
environment: production
log_level: info

providers:
  default:
    provider: ${PROVIDER}
    model: ${MODEL}

database:
  host: ${DB_HOST}
  port: ${DB_PORT}
  name: ${DB_NAME}
  user: ${DB_USER}

channels:
EOF

    # Add enabled channels
    if [[ -n "$CHANNELS" ]]; then
        IFS=',' read -ra CHANNEL_ARRAY <<< "$CHANNELS"
        for channel in "${CHANNEL_ARRAY[@]}"; do
            echo "  ${channel}:" >> "$SUPERNOVA_CONFIG_FILE"
            echo "    enabled: true" >> "$SUPERNOVA_CONFIG_FILE"
        done
    fi

    # Create secrets file
    cat > "$SUPERNOVA_SECRETS_FILE" << EOF
# Supernova secrets - DO NOT COMMIT
EOF

    if [[ -n "$API_KEY" ]]; then
        echo "SUPERNOVA_${PROVIDER^^}_API_KEY=${API_KEY}" >> "$SUPERNOVA_SECRETS_FILE"
    fi

    if [[ -n "$DB_PASSWORD" ]]; then
        echo "SUPERNOVA_DB_PASSWORD=${DB_PASSWORD}" >> "$SUPERNOVA_SECRETS_FILE"
    fi

    chmod 600 "$SUPERNOVA_SECRETS_FILE"
    chown root:root "$SUPERNOVA_SECRETS_FILE"

    log_success "Configuration generated"
}

# Show summary and prompt for confirmation
show_summary() {
    echo ""
    echo -e "${BOLD}=== Installation Summary ===${NC}"
    echo ""
    echo "  Supernova version:    $VERSION"
    echo "  Installation path:   $SUPERNOVA_BINARY"
    echo "  Config directory:     $SUPERNOVA_CONFIG_DIR"
    echo "  Data directory:       $SUPERNOVA_HOME"
    echo "  System user:          $SUPERNOVA_USER"
    echo "  Database:             ${DB_HOST}:${DB_PORT}/${DB_NAME}"
    echo ""
    echo "  Config file:          $SUPERNOVA_CONFIG_FILE"
    echo "  Secrets file:         $SUPERNOVA_SECRETS_FILE (permissions: 600)"
    echo "  Service unit:         $SUPERNOVA_UNIT_FILE"
    echo ""

    if [[ -f "$SUPERNOVA_CONFIG_FILE" ]]; then
        echo "  Status:               Configuration generated"
    else
        echo -e "  ${RED}Status:               Configuration NOT generated${NC}"
    fi

    echo ""
    echo "The following will be done:"
    echo "  1. Enable and start the systemd service"
    echo "  2. Service will run on boot automatically"
    echo ""

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_info "Non-interactive mode: proceeding without confirmation"
        return 0
    fi

    read -p "Proceed with enabling and starting the service? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation complete. Service not started."
        log_info "To start manually:"
        echo "    sudo systemctl enable supernova"
        echo "    sudo systemctl start supernova"
        exit 0
    fi
}

# Enable and start the service
start_service() {
    log_info "Enabling and starting service..."

    systemctl enable supernova
    systemctl start supernova

    # Wait a moment for service to start
    sleep 2

    if systemctl is-active --quiet supernova; then
        log_success "Service started successfully"
    else
        log_error "Service failed to start. Check logs with:"
        echo "    journalctl -u supernova -n 50"
        exit 1
    fi
}

# Final verification
verify_installation() {
    log_info "Verifying installation..."

    echo ""
    echo -e "${BOLD}=== Verification ===${NC}"
    echo ""

    # Check service status
    if systemctl is-active --quiet supernova; then
        echo -e "  ${GREEN}[OK]${NC} Service is running"
    else
        echo -e "  ${RED}[FAIL]${NC} Service is not running"
    fi

    # Check binary
    if [[ -x "$SUPERNOVA_BINARY" ]]; then
        echo -e "  ${GREEN}[OK]${NC} Binary installed"
    else
        echo -e "  ${RED}[FAIL]${NC} Binary not found"
    fi

    # Check config
    if [[ -f "$SUPERNOVA_CONFIG_FILE" ]]; then
        echo -e "  ${GREEN}[OK]${NC} Configuration exists"
    else
        echo -e "  ${RED}[FAIL]${NC} Configuration missing"
    fi

    echo ""
    echo "Useful commands:"
    echo "  systemctl status supernova   # Check service status"
    echo "  journalctl -u supernova -f  # Follow logs"
    echo "  systemctl stop supernova     # Stop service"
    echo "  systemctl restart supernova  # Restart service"
    echo ""
}

# Main installation flow
main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         Supernova Quickstart Installer           ║${NC}"
    echo -e "${BOLD}║         Version ${SUPERNOVA_INSTALLER_VERSION}                             ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"
    check_root
    detect_system
    check_prerequisites

    echo ""
    log_info "Starting installation..."

    get_version

    # Try release download, fall back to source
    if ! download_release; then
        log_warn "Falling back to source build..."
        if [[ -f "gleam.toml" ]]; then
            install_from_source
        else
            log_error "No pre-built release available and not running from source"
            log_info "Clone the repository and run this installer from the source directory:"
echo "    git clone https://github.com/manelsen/supernova"
echo "    cd supernova"
echo "    curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | bash"
            exit 1
        fi
    fi

    create_user
    create_directories
    setup_postgres
    install_systemd_unit
    run_wizard
    show_summary
    start_service
    verify_installation

    echo ""
    log_success "Installation complete!"
}

main "$@"
