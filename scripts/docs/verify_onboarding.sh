#!/usr/bin/env bash
#
# Supernova Onboarding Documentation Verifier
# =========================================
# Verifies that onboarding documentation matches the official flow.
# Run this to ensure docs stay in sync with the implementation.

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Counters (use : to avoid exit on 0 increment)
CHECKS_PASSED=0
CHECKS_FAILED=0

# Project root (assuming this script is in scripts/docs/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_DIR="$PROJECT_ROOT/docs/operations"
README="$PROJECT_ROOT/README.md"

# Logging
log_check() {
    echo -e "${BLUE}[CHECK]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Test: README mentions curl quickstart
check_readme_curl_quickstart() {
    log_check "README mentions curl quickstart..."

if grep -q "curl.*raw.githubusercontent.com.*install.sh" "$README"; then
        log_pass "README mentions official curl quickstart"
    else
        log_fail "README does not mention official curl quickstart"
    fi
}

# Test: README mentions systemd
check_readme_systemd() {
    log_check "README mentions systemd..."

    if grep -qi "systemd" "$README"; then
        log_pass "README mentions systemd"
    else
        log_fail "README does not mention systemd"
    fi
}

# Test: README does NOT show docker as primary
check_readme_docker_not_primary() {
    log_check "README does not show Docker as primary quickstart..."

    # Check if the section about docker comes after a note about it being development-only
    local docker_section=$(grep -n "Docker" "$README" | head -1 | cut -d: -f1 || echo "0")
    local dev_only_section=$(grep -ni "development only\|dev/advanced\|development only" "$README" | head -1 | cut -d: -f1 || echo "9999")

    if [[ $docker_section -gt 0 ]] && [[ $docker_section -lt $dev_only_section ]]; then
        log_fail "Docker appears before 'development only' note in README"
    else
        log_pass "Docker is positioned correctly in README"
    fi
}

# Test: ONBOARDING_OVERVIEW.md exists
check_onboarding_overview_exists() {
    log_check "ONBOARDING_OVERVIEW.md exists..."

    if [[ -f "$DOCS_DIR/ONBOARDING_OVERVIEW.md" ]]; then
        log_pass "ONBOARDING_OVERVIEW.md exists"
    else
        log_fail "ONBOARDING_OVERVIEW.md not found"
    fi
}

# Test: ONBOARDING_OVERVIEW.md mentions curl
check_onboarding_overview_curl() {
    log_check "ONBOARDING_OVERVIEW.md mentions curl..."

if grep -q "curl.*raw.githubusercontent.com.*install.sh" "$DOCS_DIR/ONBOARDING_OVERVIEW.md"; then
        log_pass "ONBOARDING_OVERVIEW.md mentions curl quickstart"
    else
        log_fail "ONBOARDING_OVERVIEW.md does not mention curl quickstart"
    fi
}

# Test: ONBOARDING_OVERVIEW.md mentions systemd
check_onboarding_overview_systemd() {
    log_check "ONBOARDING_OVERVIEW.md mentions systemd..."

    if grep -qi "systemd" "$DOCS_DIR/ONBOARDING_OVERVIEW.md"; then
        log_pass "ONBOARDING_OVERVIEW.md mentions systemd"
    else
        log_fail "ONBOARDING_OVERVIEW.md does not mention systemd"
    fi
}

# Test: ONBOARDING_OVERVIEW.md has non-interactive section
check_onboarding_non_interactive() {
    log_check "ONBOARDING_OVERVIEW.md has non-interactive mode..."

    if grep -qi "non-interactive\|ci.*automation" "$DOCS_DIR/ONBOARDING_OVERVIEW.md"; then
        log_pass "ONBOARDING_OVERVIEW.md mentions non-interactive mode"
    else
        log_fail "ONBOARDING_OVERVIEW.md does not mention non-interactive mode"
    fi
}

# Test: ONBOARDING.md exists
check_onboarding_exists() {
    log_check "ONBOARDING.md exists..."

    if [[ -f "$DOCS_DIR/ONBOARDING.md" ]]; then
        log_pass "ONBOARDING.md exists"
    else
        log_fail "ONBOARDING.md not found"
    fi
}

# Test: ONBOARDING.md mentions curl quickstart
check_onboarding_curl() {
    log_check "ONBOARDING.md mentions curl quickstart..."

    if grep -q "curl.*raw.githubusercontent.com.*install.sh" "$DOCS_DIR/ONBOARDING.md"; then
        log_pass "ONBOARDING.md mentions curl quickstart"
    else
        log_fail "ONBOARDING.md does not mention curl quickstart"
    fi
}

# Test: ONBOARD_CLI.md exists
check_onboarding_cli_exists() {
    log_check "ONBOARD_CLI.md exists..."

    if [[ -f "$DOCS_DIR/ONBOARD_CLI.md" ]]; then
        log_pass "ONBOARD_CLI.md exists"
    else
        log_fail "ONBOARD_CLI.md not found"
    fi
}

# Test: DOCKER.md exists
check_docker_doc_exists() {
    log_check "DOCKER.md exists..."

    if [[ -f "$DOCS_DIR/DOCKER.md" ]]; then
        log_pass "DOCKER.md exists"
    else
        log_fail "DOCKER.md not found"
    fi
}

# Test: DOCKER.md is marked as dev/advanced
check_docker_dev_only() {
    log_check "DOCKER.md is marked as development/advanced..."

    if grep -qi "development\|advanced\|Dev.*Advanced" "$DOCS_DIR/DOCKER.md"; then
        log_pass "DOCKER.md is marked as development/advanced"
    else
        log_fail "DOCKER.md is not marked as development/advanced"
    fi
}

# Test: DOCKER.md does not claim to be production-ready
check_docker_not_production() {
    log_check "DOCKER.md does not claim to be production-ready..."

    if grep -q "use Docker.*production\|recommended.*docker.*production\|docker.*recommended.*production\|docker.*for production$" "$DOCS_DIR/DOCKER.md"; then
        log_fail "DOCKER.md still claims Docker is production-recommended"
    else
        log_pass "DOCKER.md does not claim to be production-recommended"
    fi
}

# Test: Installer script exists
check_installer_exists() {
    log_check "Quickstart installer script exists..."

    if [[ -f "$PROJECT_ROOT/scripts/quickstart/install.sh" ]]; then
        log_pass "Quickstart installer script exists"
    else
        log_fail "Quickstart installer script not found"
    fi
}

# Test: Installer script is executable
check_installer_executable() {
    log_check "Installer script is executable..."

    if [[ -x "$PROJECT_ROOT/scripts/quickstart/install.sh" ]]; then
        log_pass "Installer script is executable"
    else
        log_fail "Installer script is not executable"
    fi
}

# Test: smoke_test.sh exists
check_smoke_test_exists() {
    log_check "Smoke test script exists..."

    if [[ -f "$PROJECT_ROOT/scripts/quickstart/smoke_test.sh" ]]; then
        log_pass "Smoke test script exists"
    else
        log_fail "Smoke test script not found"
    fi
}

# Test: smoke_test.sh is executable
check_smoke_test_executable() {
    log_check "Smoke test script is executable..."

    if [[ -x "$PROJECT_ROOT/scripts/quickstart/smoke_test.sh" ]]; then
        log_pass "Smoke test script is executable"
    else
        log_fail "Smoke test script is not executable"
    fi
}

# Test: verify_onboarding.sh exists (this script)
check_verify_script_exists() {
    log_check "Verify onboarding script exists..."

    if [[ -f "$SCRIPT_DIR/verify_onboarding.sh" ]]; then
        log_pass "Verify onboarding script exists"
    else
        log_fail "Verify onboarding script not found"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo -e "${BOLD}================================${NC}"
    echo -e "${BOLD}  Documentation Check Summary    ${NC}"
    echo -e "${BOLD}================================${NC}"
    echo ""
    echo -e "  Passed: ${GREEN}${CHECKS_PASSED}${NC}"
    echo -e "  Failed: ${RED}${CHECKS_FAILED}${NC}"
    echo ""

    if [[ $CHECKS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All documentation checks passed!${NC}"
        return 0
    else
        echo -e "${RED}Some documentation issues found.${NC}"
        return 1
    fi
}

# Main
main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║    Supernova Onboarding Documentation Verifier    ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    echo "Project root: $PROJECT_ROOT"
    echo "Docs directory: $DOCS_DIR"
    echo ""

    echo "Running documentation checks..."
    echo ""

    # README checks
    check_readme_curl_quickstart
    check_readme_systemd
    check_readme_docker_not_primary

    # ONBOARDING_OVERVIEW checks
    check_onboarding_overview_exists
    check_onboarding_overview_curl
    check_onboarding_overview_systemd
    check_onboarding_non_interactive

    # ONBOARDING checks
    check_onboarding_exists
    check_onboarding_curl

    # ONBOARD_CLI checks
    check_onboarding_cli_exists

    # DOCKER checks
    check_docker_doc_exists
    check_docker_dev_only
    check_docker_not_production

    # Scripts checks
    check_installer_exists
    check_installer_executable
    check_smoke_test_exists
    check_smoke_test_executable
    check_verify_script_exists

    print_summary
}

main "$@"
