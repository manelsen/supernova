#!/usr/bin/env bash
#
# Supernova Onboarding Documentation Verifier
# =========================================

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CHECKS_PASSED=0
CHECKS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_DIR="$PROJECT_ROOT/docs/operations"
README="$PROJECT_ROOT/README.md"

log_check() { echo -e "${BLUE}[CHECK]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; CHECKS_PASSED=$((CHECKS_PASSED + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1" >&2; CHECKS_FAILED=$((CHECKS_FAILED + 1)); }

check_readme_curl() {
    log_check "README mentions curl quickstart..."
    if grep -q "curl.*raw.githubusercontent.com.*supernova" "$README"; then
        log_pass "README mentions curl quickstart"
    else
        log_fail "README does not mention curl quickstart"
    fi
}

check_readme_docker() {
    log_check "README mentions Docker..."
    if grep -qi "docker" "$README"; then
        log_pass "README mentions Docker"
    else
        log_fail "README does not mention Docker"
    fi
}

check_readme_not_systemd() {
    log_check "README does not require systemd..."
    if grep -qi "systemd" "$README"; then
        log_fail "README still mentions systemd as primary"
    else
        log_pass "README does not require systemd"
    fi
}

check_docs_exist() {
    local docs=("ONBOARDING_OVERVIEW.md" "ONBOARDING.md" "ONBOARD_CLI.md")
    for doc in "${docs[@]}"; do
        log_check "$doc exists..."
        if [[ -f "$DOCS_DIR/$doc" ]]; then
            log_pass "$doc exists"
        else
            log_fail "$doc not found"
        fi
    done
}

check_onboarding_curl() {
    log_check "ONBOARDING_OVERVIEW.md mentions curl..."
    if grep -q "curl.*raw.githubusercontent.com.*supernova" "$DOCS_DIR/ONBOARDING_OVERVIEW.md"; then
        log_pass "ONBOARDING_OVERVIEW.md mentions curl quickstart"
    else
        log_fail "ONBOARDING_OVERVIEW.md does not mention curl"
    fi
}

check_onboarding_docker() {
    log_check "ONBOARDING_OVERVIEW.md mentions Docker..."
    if grep -qi "docker" "$DOCS_DIR/ONBOARDING_OVERVIEW.md"; then
        log_pass "ONBOARDING_OVERVIEW.md mentions Docker"
    else
        log_fail "ONBOARDING_OVERVIEW.md does not mention Docker"
    fi
}

check_cli_exists() {
    log_check "CLI script exists..."
    if [[ -f "$PROJECT_ROOT/scripts/quickstart/supernova" ]]; then
        log_pass "CLI script exists"
    else
        log_fail "CLI script not found"
    fi
}

check_cli_executable() {
    log_check "CLI script is executable..."
    if [[ -x "$PROJECT_ROOT/scripts/quickstart/supernova" ]]; then
        log_pass "CLI script is executable"
    else
        log_fail "CLI script is not executable"
    fi
}

print_summary() {
    echo ""
    echo -e "${BOLD}================================${NC}"
    echo -e "${BOLD}  Summary                      ${NC}"
    echo -e "${BOLD}================================${NC}"
    echo ""
    echo -e "  Passed: ${GREEN}${CHECKS_PASSED}${NC}"
    echo -e "  Failed: ${RED}${CHECKS_FAILED}${NC}"
    echo ""

    [[ $CHECKS_FAILED -eq 0 ]] && return 0 || return 1
}

main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║    Supernova Onboarding Documentation Verifier    ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    check_readme_curl
    check_readme_docker
    check_readme_not_systemd
    check_docs_exist
    check_onboarding_curl
    check_onboarding_docker
    check_cli_exists
    check_cli_executable

    print_summary
}

main "$@"
