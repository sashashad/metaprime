#!/usr/bin/env bash
# Nightly ClickHouse backup (data + configs)
# ------------------------------------------
# 1. Создаёт дамп уровня таблиц через clickhouse-backup
# 2. Архивирует конфигурационные файлы ClickHouse
# ------------------------------------------
set -euo pipefail

CLICKHOUSE_BACKUP_BIN="/usr/local/bin/clickhouse-backup"   # скорректируйте при необходимости
LOG_FILE="/var/log/clickhouse_backup.log"

# --- 1. Data backup -------------------------------------------------
BACKUP_NAME="clickhouse-backup-$(date +%F)"   # например: backup-2025-06-21
echo "$(date '+%F %T') - Creating ClickHouse data backup: ${BACKUP_NAME}" >> "$LOG_FILE"
"$CLICKHOUSE_BACKUP_BIN" create "$BACKUP_NAME" >> "$LOG_FILE" 2>&1

# --- 2. Config backup ----------------------------------------------
CONFIG_SRC="/etc/clickhouse-server"
CONFIG_DST="/opt/backups/clickhouse/configs"
CONFIG_ARCHIVE="${CONFIG_DST}/clickhouse-config-$(date +%F).tar.gz"

echo "$(date '+%F %T') - Archiving ClickHouse configs to ${CONFIG_ARCHIVE}" >> "$LOG_FILE"
mkdir -p "$CONFIG_DST"
tar -czf "$CONFIG_ARCHIVE" -C "$CONFIG_SRC" . >> "$LOG_FILE" 2>&1

echo "$(date '+%F %T') - Backup finished" >> "$LOG_FILE"
