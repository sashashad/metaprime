#!/bin/bash

# =================================================================
# Универсальный скрипт резервного копирования PostgreSQL (функциональный стиль)
# Логика и пути полностью сохранены из исходного «Archive Postgresql Configs»
# =================================================================
# 1. Бэкап всех БД (кроме списка исключений)
# 2. Архивация конфигов PostgreSQL и PgBouncer, история .bash/.psql
# 3. Очистка архивов и дампов старше 5 дней
# 4. Централизованный лог: /var/log/backup.log
# =================================================================

# ---------- ПАРАМЕТРЫ ---------------------------------------------
BACKUP_DIR="/opt/backups/base"            # Дампы БД
CONFIG_BACKUP_DIR="/opt/backups/configs"  # Архивы конфигов
LOG_FILE="/var/log/backup.log"            # Файл лога
POSTGRES_DATA_DIR="/db/tantor-se-16/data" # data‑dir PostgreSQL
EXCLUDED_DATABASES=("fias" "gisjkh" "postgres")

# ---------- УТИЛИТАРНЫЕ ФУНКЦИИ ------------------------------------
log_message() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE"
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR" "$CONFIG_BACKUP_DIR"
}

# ---------- 1. БЭКАП БАЗ ДАННЫХ ------------------------------------
backup_databases() {
    local databases
    databases=$(psql -qAt -c "SELECT datname FROM pg_database WHERE datistemplate = false;")
    local DATE=$(date +%d-%m-%Y)
    local success=true

    for db in $databases; do
        if [[ " ${EXCLUDED_DATABASES[*]} " == *" $db "* ]]; then
            log_message INFO "БД '$db' исключена из бэкапа."
            continue
        fi

        if pg_dump -F c -Z9 -b -v -f "${BACKUP_DIR}/${DATE}-${db}.backup" "$db"; then
            log_message INFO "Бэкап БД '$db' создан."
        else
            log_message ERROR "Ошибка бэкапа БД '$db'."
            success=false
        fi
    done

    \$success
}

cleanup_old_backups() {
    local removed
    removed=$(find "$BACKUP_DIR" -type f -mtime +5 -exec rm {} \; -print | wc -l)
    [[ $? -eq 0 ]] && \
        log_message INFO "Удалено старых дампов: $removed." || \
        log_message ERROR "Ошибка очистки старых дампов."
}

# ---------- 2. АРХИВИРОВАНИЕ КОНФИГОВ -----------------------------
archive_configs() {
    local DATE=$(date +%d-%m-%Y)

    # Архив конфигов PostgreSQL
    tar -czvf "${CONFIG_BACKUP_DIR}/${DATE}-postgresql_configs.tar.gz" \
        -C "$POSTGRES_DATA_DIR" \
        postgresql.conf pg_hba.conf pg_ident.conf postgresql.auto.conf \
        postmaster.opts PG_VERSION current_logfiles && \
        log_message INFO "Архив конфигов PostgreSQL создан." || \
        log_message ERROR "Ошибка архивации конфигов PostgreSQL."

    # Архив конфигов PgBouncer (без mkauth.py)
    tar --exclude="mkauth.py" -czvf "${CONFIG_BACKUP_DIR}/${DATE}-pgbouncer_configs.tar.gz" \
        -C /opt/tantor/etc pgbouncer && \
        log_message INFO "Архив конфигов PgBouncer создан." || \
        log_message ERROR "Ошибка архивации конфигов PgBouncer."

    # История команд пользователя postgres
    for hist in /var/lib/postgresql/.bash_history /var/lib/postgresql/.psql_history; do
        cp -v "$hist" "$CONFIG_BACKUP_DIR/" && \
            log_message INFO "Скопирован $(basename "$hist")." || \
            log_message ERROR "Ошибка копирования $(basename "$hist")."
    done

    # Очистка архивов конфигов старше 5 дней
    local removed
    removed=$(find "$CONFIG_BACKUP_DIR" -type f -mtime +5 -exec rm {} \; -print | wc -l)
    [[ $? -eq 0 ]] && \
        log_message INFO "Удалено старых архивов конфигов: $removed." || \
        log_message ERROR "Ошибка удаления архивов конфигов."
}

# ---------- ГЛАВНАЯ ФУНКЦИЯ ---------------------------------------
main() {
    ensure_dirs

    if backup_databases; then
        cleanup_old_backups
    else
        log_message WARNING "Очистка дампов пропущена из‑за ошибок бэкапа."
    fi

    archive_configs
}

main "$@"
exit 0
