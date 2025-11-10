#!/bin/bash

# --- Logging Functions & Colors ---
# Define colors for log messages
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[0;33m"
readonly COLOR_ERROR="\033[0;31m"

# Function to log messages with a specific color and emoji
log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }
# ------------------------------------

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_ROOT_REPOSITORY=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
SERVICE_NAME=$(basename "$PATH_TO_ROOT_REPOSITORY")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_ROOT_REPOSITORY")

function load_env_file() {
    local env_file="$1"
    if [ -z "$env_file" ] || [ ! -f "$env_file" ]; then
        log_error "Env file not found: $env_file"
        return 1
    fi

    log_info "Loading environment variables from $env_file"

    # Read .env safely: ignore empty lines and comments, support lines like KEY=VALUE and export KEY=VALUE
    while IFS= read -r line || [ -n "$line" ]; do
        # strip CR, skip empty or commented lines
        line="${line%%$'\r'}"
        [[ -z "$line" || "${line#"${line%%[![:space:]]*}"}" == "#" ]] && continue
        # remove leading "export " if present
        line="${line#export }"
        # Only process KEY=... pairs
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            # Use eval to allow quoted values; this runs in the current shell and exports the var
            eval "export $line"
        else
            log_warn "Skipping invalid line in env file: $line"
        fi
    done < "$env_file"

    log_success "Environment variables loaded from $env_file"
    return 0
}

function generate_docker_compose() {
    local env_file="$1"
    local example_file="$PATH_TO_ROOT_REPOSITORY/docker-compose.yml.example"
    local target_file="$PATH_TO_ROOT_REPOSITORY/docker-compose.yml"

    if [ ! -f "$example_file" ]; then
        log_error "Example docker-compose not found: $example_file"
        return 1
    fi

    load_env_file "$env_file" || return 1

    # Ensure envsubst is available; fall back to simple substitution if not installed
    if command -v envsubst >/dev/null 2>&1; then
        log_info "Generating $target_file from $example_file using envsubst"
        envsubst < "$example_file" > "$target_file" || { log_error "envsubst failed"; return 1; }
    else
        log_warn "envsubst not available; attempting simple variable replacement"
        # This fallback will replace ${VAR} occurrences using current environment variables
        # It's less robust but works for common cases
        awk '
        { line = $0
          while (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
            var = substr(line, RSTART+2, RLENGTH-3)
            repl = ENVIRON[var]
            if (repl == "") repl = ""
            line = substr(line, 1, RSTART-1) repl substr(line, RSTART+RLENGTH)
          }
          print line
        }' "$example_file" > "$target_file" || { log_error "fallback substitution failed"; return 1; }
    fi

    # Set ownership to repository owner
    if [ -n "$REPOSITORY_OWNER" ]; then
        chown "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$target_file" 2>/dev/null || log_warn "Could not chown $target_file"
    fi

    log_success "Generated $target_file"
    return 0
}

function main() {
    local ENV_FILE_PATH="$PATH_TO_ROOT_REPOSITORY/.env"

    if [ ! -f "$ENV_FILE_PATH" ]; then
        log_error ".env file not found at $ENV_FILE_PATH"
        log_warn "Please create the .env file from .env.example, then fill out the variables."
        exit 1
    fi

    generate_docker_compose "$ENV_FILE_PATH" || {
        log_error "Failed to generate docker-compose.yml"
        exit 1
    }
}

main
