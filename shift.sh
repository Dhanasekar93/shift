#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# shift.sh — Manage the Shift migration system (Docker-based)
# Usage: ./shift.sh {start|stop|restart|status|logs|setup|seed|test-slack|destroy}
# ============================================================

COMPOSE_FILE="docker-compose.dev.yml"
PROJECT_NAME="shift"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[shift]${NC} $*"; }
warn() { echo -e "${YELLOW}[shift]${NC} $*"; }
err()  { echo -e "${RED}[shift]${NC} $*" >&2; }

compose() {
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
}

wait_for_mysql() {
  log "Waiting for MySQL to be ready..."
  local retries=30
  while [ $retries -gt 0 ]; do
    if docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec -T db mysqladmin -uroot -proot ping 2>/dev/null | grep -q "alive"; then
      log "MySQL is ready!"
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  err "MySQL did not become ready in time"
  return 1
}

wait_for_rails() {
  log "Waiting for Rails to be ready..."
  local retries=60
  while [ $retries -gt 0 ]; do
    if curl -sf http://localhost:3000/ > /dev/null 2>&1; then
      log "Rails is ready!"
      return 0
    fi
    retries=$((retries - 1))
    sleep 3
  done
  warn "Rails may not be fully ready — check logs with: ./shift.sh logs"
}

cmd_start() {
  log "Starting Shift..."

  # Check for Slack config
  if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL_ID:-}" ]; then
    log "Slack Bot Token and Channel ID detected — notifications enabled"
  elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    log "Slack Webhook URL detected — notifications enabled (webhook mode)"
  else
    warn "No Slack config found. Set SLACK_BOT_TOKEN + SLACK_CHANNEL_ID for notifications."
    warn "  export SLACK_BOT_TOKEN=xoxb-your-token"
    warn "  export SLACK_CHANNEL_ID=C0123456789"
  fi

  compose up -d --build

  wait_for_mysql
  wait_for_rails

  echo ""
  log "============================================"
  log "  Shift is running!"
  log "  UI:    ${BLUE}http://localhost:3000${NC}"
  log "  Nginx: ${BLUE}http://localhost:8080${NC} (admin/admin123)"
  log "============================================"
  echo ""
  log "First time? Run: ${YELLOW}./shift.sh setup${NC}"
}

cmd_stop() {
  log "Stopping Shift..."
  compose down
  log "Stopped."
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  echo -e "${BLUE}=== Shift Services ===${NC}"
  compose ps
  echo ""

  # Check each service
  if curl -sf http://localhost:3000/ > /dev/null 2>&1; then
    echo -e "  Rails UI:  ${GREEN}UP${NC} — http://localhost:3000"
  else
    echo -e "  Rails UI:  ${RED}DOWN${NC}"
  fi

  if docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec -T db mysqladmin -uroot -proot ping 2>/dev/null | grep -q "alive"; then
    echo -e "  MySQL:     ${GREEN}UP${NC}"
  else
    echo -e "  MySQL:     ${RED}DOWN${NC}"
  fi

  if docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec -T shift pgrep -f "shift.*runner" > /dev/null 2>&1; then
    echo -e "  Runner:    ${GREEN}UP${NC}"
  else
    echo -e "  Runner:    ${YELLOW}MAY NOT BE RUNNING${NC} — check logs"
  fi

  echo ""
  if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL_ID:-}" ]; then
    echo -e "  Slack:     ${GREEN}CONFIGURED${NC} (Bot Token)"
  elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    echo -e "  Slack:     ${GREEN}CONFIGURED${NC} (Webhook)"
  else
    echo -e "  Slack:     ${YELLOW}NOT CONFIGURED${NC}"
  fi
}

cmd_logs() {
  local service="${1:-}"
  if [ -n "$service" ]; then
    compose logs -f "$service"
  else
    compose logs -f
  fi
}

cmd_setup() {
  log "Setting up Shift database..."
  wait_for_mysql

  compose exec -T shift bash -c '
    cd /opt/code/ui
    export RAILS_ENV=production
    export SECRET_KEY_BASE=${SECRET_KEY_BASE:-shift_dev_secret}
    bundle exec rake db:create 2>/dev/null || true
    bundle exec rake db:schema:load 2>/dev/null || bundle exec rake db:migrate
    bundle exec rake db:seed
  '

  log "Inserting default cluster (localhost → db:3306)..."
  compose exec -T db mysql -uroot -proot -e "
    INSERT IGNORE INTO shift_production.clusters
      (name, app, rw_host, port, admin_review_required, is_staging)
    VALUES
      ('default-cluster', 'local-app', 'db', 3306, 0, 1);
  " 2>/dev/null

  log "Creating sample test database..."
  compose exec -T db mysql -uroot -proot -e "
    CREATE DATABASE IF NOT EXISTS test_app;
    USE test_app;
    CREATE TABLE IF NOT EXISTS users (
      id INT AUTO_INCREMENT PRIMARY KEY,
      name VARCHAR(255),
      email VARCHAR(255),
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    INSERT IGNORE INTO users (id, name, email) VALUES (1, 'test', 'test@example.com');
  " 2>/dev/null

  echo ""
  log "Setup complete! Open ${BLUE}http://localhost:3000${NC} and file a migration."
}

cmd_test_slack() {
  if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL_ID:-}" ]; then
    err "SLACK_BOT_TOKEN and SLACK_CHANNEL_ID must be set"
    err "  export SLACK_BOT_TOKEN=xoxb-your-token"
    err "  export SLACK_CHANNEL_ID=C0123456789"
    exit 1
  fi

  log "Testing Slack integration..."
  RESULT=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"channel\":\"$SLACK_CHANNEL_ID\",\"text\":\":white_check_mark: *Shift Migration System* — Slack integration test successful!\"}")

  OK=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null)
  if [ "$OK" = "True" ]; then
    log "Slack test message sent successfully! Check your channel."
  else
    ERR=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
    err "Slack test failed: $ERR"
    if [ "$ERR" = "not_allowed_token_type" ]; then
      err "You're using an App-Level Token (xapp-...). You need the Bot User OAuth Token (xoxb-...)."
      err "Go to api.slack.com/apps → your app → OAuth & Permissions → Bot User OAuth Token"
    fi
  fi
}

cmd_destroy() {
  warn "This will remove all containers, volumes, and data!"
  read -p "Are you sure? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    compose down -v --remove-orphans
    log "Destroyed."
  else
    log "Cancelled."
  fi
}

cmd_help() {
  cat <<EOF
${BLUE}Shift Migration System — Management Script${NC}

Usage: ./shift.sh <command> [args]

Commands:
  ${GREEN}start${NC}        Build and start all services (MySQL, Rails UI, Runner, Nginx)
  ${GREEN}stop${NC}         Stop all services
  ${GREEN}restart${NC}      Restart all services
  ${GREEN}status${NC}       Show service status
  ${GREEN}logs${NC} [svc]   Tail logs (optionally for a specific service: db, shift)
  ${GREEN}setup${NC}        Initialize database, seed data, create default cluster
  ${GREEN}test-slack${NC}   Send a test Slack message
  ${GREEN}destroy${NC}      Remove all containers and volumes (⚠️  deletes data)

Environment Variables:
  SLACK_BOT_TOKEN    Bot User OAuth Token (xoxb-...)
  SLACK_CHANNEL_ID   Slack channel ID (C0123456789)
  SLACK_WEBHOOK_URL  Incoming Webhook URL (fallback)

Quick Start:
  ${YELLOW}./shift.sh start${NC}      # Build & start
  ${YELLOW}./shift.sh setup${NC}      # Initialize DB (first time only)
  ${YELLOW}open http://localhost:3000${NC}  # Open UI
EOF
}

# Main
case "${1:-help}" in
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  status)     cmd_status ;;
  logs)       shift; cmd_logs "$@" ;;
  setup)      cmd_setup ;;
  test-slack) cmd_test_slack ;;
  destroy)    cmd_destroy ;;
  help|--help|-h) cmd_help ;;
  *)
    err "Unknown command: $1"
    cmd_help
    exit 1
    ;;
esac
