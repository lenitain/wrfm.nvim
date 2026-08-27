#!/usr/bin/env bash
set -eu -o pipefail

# test-runner.sh — colored output, TAP/minimal/verbose modes, CI detection.
# Runs tests inside Neovim via tests/busted.lua (no external busted needed).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODE="verbose"
FILTER=""
COVERAGE=0
JOBS=""

# ---------------------------------------------------------------------------
# Colors (disabled in CI or when stdout is not a tty)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${CI:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}Usage:${RESET} test-runner.sh [OPTIONS]

${BOLD}Options:${RESET}
  --verbose     Full output with test names (default)
  --tap         TAP format output
  --minimal     Minimal output (dots per pass, F per fail)
  --filter PAT  Run only tests matching PAT
  --coverage    Enable LuaCov coverage collection
  --jobs N      Parallel test jobs (busted --jobs)
  -h, --help    Show this help

${BOLD}Environment:${RESET}
  CI            Set to any value to disable colors
  WRFM_SKIP_ORACLE=1  Skip oracle golden tests
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --verbose)  MODE="verbose" ;;
    --tap)      MODE="tap" ;;
    --minimal)  MODE="minimal" ;;
    --filter)   shift; FILTER="$1" ;;
    --coverage) COVERAGE=1 ;;
    --jobs)     shift; JOBS="$1" ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Build busted arguments (passed after -- to nvim -l tests/busted.lua)
# ---------------------------------------------------------------------------
BUSTED_ARGS=()

case "$MODE" in
  tap)
    BUSTED_ARGS+=("--outputHandler" "busted.output_handler.TAP")
    ;;
  minimal)
    BUSTED_ARGS+=("--outputHandler" "busted.output_handler.utfTerminal")
    ;;
  verbose)
    BUSTED_ARGS+=("--verbose")
    ;;
esac

if [ -n "$FILTER" ]; then
  BUSTED_ARGS+=("--filter" "$FILTER")
fi

if [ "$COVERAGE" -eq 1 ]; then
  BUSTED_ARGS+=("--coverage")
fi

if [ -n "$JOBS" ]; then
  BUSTED_ARGS+=("--jobs" "$JOBS")
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
cd "$REPO_DIR"

printf "${BOLD}${CYAN}wrfm.nvim test runner${RESET} [mode=${BOLD}%s${RESET}]\n" "$MODE"
printf "${CYAN}────────────────────────────────────────${RESET}\n"

START_TIME=$(date +%s)

if [ ${#BUSTED_ARGS[@]} -gt 0 ]; then
  nvim -l tests/busted.lua -- "${BUSTED_ARGS[@]}"
  STATUS=$?
else
  nvim -l tests/busted.lua
  STATUS=$?
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

printf "${CYAN}────────────────────────────────────────${RESET}\n"
if [ "$STATUS" -eq 0 ]; then
  printf "${BOLD}${GREEN}ALL PASSED${RESET} (%ds)\n" "$ELAPSED"
else
  printf "${BOLD}${RED}FAILURES${RESET} (%ds)\n" "$ELAPSED"
fi

if [ "$COVERAGE" -eq 1 ] && [ -f luacov.stats.out ]; then
  printf "\n${CYAN}Coverage report:${RESET}\n"
  if command -v luacov &>/dev/null; then
    luacov
    if [ -f luacov.report.out ]; then
      head -20 luacov.report.out
      printf "${CYAN}Full report: %s/luacov.report.out${RESET}\n" "$REPO_DIR"
    fi
  else
    printf "${YELLOW}luacov not found; stats written to luacov.stats.out${RESET}\n"
  fi
fi

exit "$STATUS"
