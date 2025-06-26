#!/bin/bash

# =================================================================
# Адаптированный скрипт резервного копирования PostgreSQL
# (стиль унифицирован с новым корпоративным шаблоном, логика
#  полностью сохранена — пути и параметры не тронуты)
# =================================================================
# 1. Логический бэкап всех БД кроме исключённых.
# 2. Архивация конфигураций PostgreSQL, PgBouncer и RegisterX JCP.
# 3. Копирование истории команд пользователя postgres.
# 4. Удаление бэкапов старше 5 дней.
# 5. Централизованное логирование в /var/log/backup.log.
# =================================================================

# ---------- Параметры ------------------------------------------------
BACKUP_DIR="/opt/backups/base/"          # Директория дампов
CONFIG_BACKUP_DIR="/opt/backups/configs" # Директория архивов конфигов
LOG_FILE="/var/log/backup.log"           # Единый лог
EXCLUDED_DATABASES=("fias" "gisjkh" "postgres")

# ---------- Утилитарные функции --------------------------------------
log_message() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE"
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR" "$CONFIG_BACKUP_DIR"
}

# ---------- 1. Логический бэкап -------------------------------------
backup_databases() {
    local databases
    databases=$(psql -qAt -c "SELECT datname FROM pg_database WHERE datistemplate = false;")
    local success=true
    local DATE=$(date +%d-%m-%Y)

    for db in $databases; do
        if [[ " ${EXCLUDED_DATABASES[*]} " == *" $db "* ]]; then
            log_message INFO "БД '$db' исключена из резервного копирования."
            continue
        fi

        if pg_dump -F c -Z9 -b -v -f "${BACKUP_DIR}${DATE}-${db}.backup" "$db"; then
            log_message INFO "Резервная копия БД '$db' создана."
        else
            log_message ERROR "Ошибка резервного копирования БД '$db'."
            success=false
        fi
    done

    $success
}

cleanup_old_backups() {
    local removed
    removed=$(find "$BACKUP_DIR" -type f -mtime +5 -exec rm {} \; -print | wc -l)
    if [[ $? -eq 0 ]]; then
        log_message INFO "Удалено старых дампов: $removed."
    else
        log_message ERROR "Ошибка очистки старых дампов."
    fi
}

# ---------- 2. Архивирование конфигов --------------------------------
archive_configs() {
    local DATE=$(date +%d-%m-%Y)
    ensure_dirs

    # PostgreSQL configs (весь каталог v14)
    tar -czvf "${CONFIG_BACKUP_DIR}/${DATE}-postgresql_configs.tar.gz" \
        /etc/postgresql/14/main \
        && log_message INFO "Архив конфигов PostgreSQL создан." \
        || log_message ERROR "Ошибка архивации конфигов PostgreSQL."

    # PgBouncer configs (исключая потенциально проблемные скрипты)
    tar --exclude="mkauth.py" -czvf "${CONFIG_BACKUP_DIR}/${DATE}-pgbouncer_configs.tar.gz" \
        /etc/pgbouncer \
        && log_message INFO "Архив конфигов PgBouncer создан." \
        || log_message ERROR "Ошибка архивации конфигов PgBouncer."

    # RegisterX JCP JDK configs
    tar -czvf "${CONFIG_BACKUP_DIR}/${DATE}-signers_jcp_jdk_configs.tar.gz" \
        /opt/registerx/jcp/ \
        && log_message INFO "Архив конфигов RegisterX JCP JDK создан." \
        || log_message ERROR "Ошибка архивации конфигов RegisterX JCP JDK."

    # Bash/psql history
    for hist in /opt/postgresql/.bash_history /opt/postgresql/.psql_history; do
        cp -v "$hist" "$CONFIG_BACKUP_DIR/" \
            && log_message INFO "Скопирован $(basename "$hist")." \
            || log_message ERROR "Ошибка копирования $(basename "$hist")."
    done

    # Удаляем старые архивы конфигов
    local removed
    removed=$(find "$CONFIG_BACKUP_DIR" -type f -mtime +5 -exec rm {} \; -print | wc -l)
    if [[ $? -eq 0 ]]; then
        log_message INFO "Удалено старых архивов конфигов: $removed."
    else
        log_message ERROR "Ошибка удаления старых архивов конфигов."
    fi
}

# ---------- Основной поток ------------------------------------------
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
