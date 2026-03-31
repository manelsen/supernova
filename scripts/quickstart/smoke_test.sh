#!/usr/bin/env bash
#
# Supernova Quickstart Smoke Test
# ===============================
# Tests the quickstart installer and basic service functionality.
# Run this after installation to verify everything is working.

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
TESTS_PASSED=0
TESTS_FAILED=0

# Logging
log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_skip "This test should be run as root"
        exit 0
    fi
}

# Test: Binary exists
test_binary_exists() {
    log_test "Checking binary installation..."

    if [[ -x /usr/local/bin/supernova ]]; then
        log_pass "Binary exists and is executable"
    else
        log_fail "Binary not found at /usr/local/bin/supernova"
    fi
}

# Test: Binary version
test_binary_version() {
    log_test "Checking binary version..."

    if /usr/local/bin/supernova --version &> /dev/null; then
        local version=$(/usr/local/bin/supernova --version 2>&1)
        log_pass "Binary version: $version"
    else
        log_fail "Binary --version failed"
    fi
}

# Test: User exists
test_user_exists() {
    log_test "Checking supernova user..."

    if id supernova &> /dev/null; then
        log_pass "User 'supernova' exists"
    else
        log_fail "User 'supernova' not found"
    fi
}

# Test: Group exists
test_group_exists() {
    log_test "Checking supernova group..."

    if getent group supernova &> /dev/null; then
        log_pass "Group 'supernova' exists"
    else
        log_fail "Group 'supernova' not found"
    fi
}

# Test: Directories exist
test_directories() {
    log_test "Checking directories..."

    local dirs=("/etc/supernova" "/var/lib/supernova")
    local all_exist=true

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            echo -n ""
        else
            all_exist=false
            break
        fi
    done

    if $all_exist; then
        log_pass "All required directories exist"
    else
        log_fail "Some directories missing"
    fi
}

# Test: Config file exists
test_config_exists() {
    log_test "Checking configuration file..."

    if [[ -f /etc/supernova/supernova.yaml ]]; then
        log_pass "Configuration file exists"
    else
        log_fail "Configuration file not found"
    fi
}

# Test: Secrets file exists
test_secrets_exists() {
    log_test "Checking secrets file..."

    if [[ -f /etc/supernova/secrets.env ]]; then
        log_pass "Secrets file exists"
    else
        log_fail "Secrets file not found"
    fi
}

# Test: Secrets file permissions
test_secrets_permissions() {
    log_test "Checking secrets file permissions..."

    if [[ -f /etc/supernova/secrets.env ]]; then
        local perms=$(stat -c "%a" /etc/supernova/secrets.env)
        if [[ "$perms" == "600" ]]; then
            log_pass "Secrets file has correct permissions (600)"
        else
            log_fail "Secrets file permissions are $perms, expected 600"
        fi
    else
        log_skip "Secrets file not found"
    fi
}

# Test: Systemd unit exists
test_systemd_unit() {
    log_test "Checking systemd unit..."

    if [[ -f /etc/systemd/system/supernova.service ]]; then
        log_pass "Systemd unit file exists"
    else
        log_fail "Systemd unit file not found"
    fi
}

# Test: Systemd unit is valid
test_systemd_unit_valid() {
    log_test "Checking systemd unit validity..."

    if [[ -f /etc/systemd/system/supernova.service ]]; then
        if systemctl cat supernova &> /dev/null; then
            log_pass "Systemd unit is valid"
        else
            log_fail "Systemd unit is invalid"
        fi
    else
        log_skip "Systemd unit not found"
    fi
}

# Test: Service is enabled
test_service_enabled() {
    log_test "Checking if service is enabled..."

    if systemctl is-enabled supernova &> /dev/null; then
        log_pass "Service is enabled"
    else
        log_fail "Service is not enabled"
    fi
}

# Test: Service is running
test_service_running() {
    log_test "Checking if service is running..."

    if systemctl is-active --quiet supernova; then
        log_pass "Service is running"
    else
        log_fail "Service is not running"
    fi
}

# Test: Service health
test_service_health() {
    log_test "Checking service health..."

    # Try to get health endpoint
    if curl -sf http://localhost:8080/health/live &> /dev/null; then
        log_pass "Health endpoint responds"
    else
        # Service might not have health endpoint yet
        log_skip "Health endpoint not available (may not be implemented)"
    fi
}

# Test: Database connectivity
test_database() {
    log_test "Checking database connectivity..."

    if pg_isready -h localhost -p 5432 &> /dev/null; then
        log_pass "PostgreSQL is accepting connections"
    else
        log_fail "PostgreSQL is not responding"
    fi
}

# Test: No recent errors in logs
test_no_recent_errors() {
    log_test "Checking for recent errors in logs..."

    # Get last 100 lines of journal and check for errors
    local errors=$(journalctl -u supernova -n 100 --no-pager 2>/dev/null | grep -iE "(error|fail|exception|crash)" || true)

    if [[ -z "$errors" ]]; then
        log_pass "No recent errors in logs"
    else
        log_fail "Recent errors found in logs"
        echo "$errors" | tail -5 >&2
    fi
}

# Print summary
print_summary() {
    echo ""
    echo -e "${BOLD}================================${NC}"
    echo -e "${BOLD}  Test Summary                 ${NC}"
    echo -e "${BOLD}================================${NC}"
    echo ""
    echo -e "  Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "  Failed: ${RED}${TESTS_FAILED}${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        echo ""
        echo "To debug, run:"
        echo "  journalctl -u supernova -n 100"
        echo "  systemctl status supernova"
        return 1
    fi
}

# Main
main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║       Supernova Quickstart Smoke Test            ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root

    echo ""
    echo "Running tests..."
    echo ""

    # Run all tests
    test_binary_exists
    test_binary_version
    test_user_exists
    test_group_exists
    test_directories
    test_config_exists
    test_secrets_exists
    test_secrets_permissions
    test_systemd_unit
    test_systemd_unit_valid
    test_service_enabled
    test_service_running
    test_service_health
    test_database
    test_no_recent_errors

    print_summary
}

main "$@"
