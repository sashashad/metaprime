#!/bin/bash

# Лог-файл
LOG_FILE="/var/log/backup.log"

# Функция для логирования сообщений
log_message() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$LOG_FILE"
}

# Функция отображения справки
show_help() {
    echo
    echo "Использование: $0 <nfs_backup_dir>"
    echo
    echo "Этот скрипт предназначен для создания резервных копий баз данных PostgreSQL и их копирования на NFS-шару."
    echo "Также данный скрипт валидирует созданные резервные копии баз данных и пользователей"
    echo
    echo "Перед использованием убедитесь, что NFS-шара доступна на целевом сервере с помощью команды \"showmount -e <nfs-server>\""
    echo
    echo "Аргументы:"
    echo "  <nfs_backup_dir>: Путь к NFS-шаре для размещения резервных копий."
    echo
    echo "Пример использования:"
    echo "  $0 /mnt/gisogd_backup"
    echo
}

# Проверяем, если был запрошен help
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    show_help
    exit 0
fi

# Проверяем, что передан один аргумент
if [ "$#" -ne 1 ]; then
    log_message "ERROR" "Недостаточно аргументов."
    show_help
    exit 1
fi

# NFS-шара для резервных копий
NFS_BACKUP_DIR="$1"
DATE=$(date +%d-%m-%Y)

# Настройки для отправки почты
MAIL_TO="your_email@example.com"
MAIL_SUBJECT="Отчет о восстановлении баз данных"

# Настройки для отправки Telegram-уведомлений
TELEGRAM_BOT_TOKEN="your_telegram_bot_token"
TELEGRAM_CHAT_ID="your_telegram_chat_id"

# Функция для отправки почты
send_email() {
    local subject="$1"
    local body="$2"
    echo "$body" | mail -s "$subject" "$MAIL_TO"
}

# Функция для отправки Telegram-уведомления
send_telegram() {
    local message="$1"
    curl -s -X POST https://api.telegram.org/bot"$TELEGRAM_BOT_TOKEN"/sendMessage -d chat_id="$TELEGRAM_CHAT_ID" -d text="$message"
}

# Создание необходимых директорий для резервных копий
# mkdir -p "$NFS_BACKUP_DIR/conf" "$NFS_BACKUP_DIR/service"

# Получаем список всех баз данных
databases=$(psql -U postgres -qAt -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

# Проверяем, удалось ли получить список баз данных
if [ -z "$databases" ]; then
    log_message "ERROR" "Не удалось получить список баз данных."
    exit 1
fi

# Список баз данных для резервного копирования
databases=("ias_gorizont_filestorage")
#databases=("ias_gorizont_filestorage" "rosreestr_etl" "ias_gorizont")

# Создание резервных копий каждой базы данных
backup_success=true

for db in "${databases[@]}"; do
    backup_file="$NFS_BACKUP_DIR/$DATE-${db}.backup"

    # Команда для создания резервной копии
    pg_dump -U postgres -F c -b -v "$db" > "$backup_file"

    # Проверка успешности выполнения команды
    if [ $? -eq 0 ]; then
        log_message "INFO" "Резервная копия базы данных '$db' успешно создана: $backup_file"
    else
        log_message "ERROR" "Ошибка при создании резервной копии базы данных '$db'."
        backup_success=false  # Установить флаг в false, если резервное копирование не удалось
    fi
done

# Резервное копирование пользователей и их привилегий
user_backup_file="$NFS_BACKUP_DIR/$DATE-users.sql"
pg_dumpall -U postgres --roles-only > "$user_backup_file"
if [ $? -eq 0 ]; then
    log_message "INFO" "Резервная копия пользователей успешно создана: $user_backup_file"
else
    log_message "ERROR" "Ошибка при создании резервной копии пользователей."
fi

# Поиск и резервное копирование конфигурационных файлов
config_files=$(find /srv/pgsql/16/data/ -type f \( -name "pg_hba.conf" -o -name "postgresql.conf" \) 2>/dev/null)
for config_file in $config_files; do
    base_name=$(basename "$config_file")
    backup_path="$NFS_BACKUP_DIR/conf/$DATE-${base_name}"
    cp "$config_file" "$backup_path"
    if [ $? -eq 0 ]; then
        log_message "INFO" "Резервная копия $base_name успешно создана в $backup_path."
    else
        log_message "ERROR" "Ошибка при создании резервной копии $base_name."
    fi
done

# Резервное копирование директории postgresql-16.service.d
service_dir="/etc/systemd/system/postgresql-16.service.d/"
service_backup_file="$NFS_BACKUP_DIR/service/$DATE-postgresql-16.service.d.tar.gz"
if [ -d "$service_dir" ]; then
    if tar -czf "$service_backup_file" -C "$(dirname "$service_dir")" "$(basename "$service_dir")"; then
        log_message "INFO" "Резервная копия директории postgresql-16.service.d успешно создана: $service_backup_file"
    else
        log_message "ERROR" "Ошибка при создании резервной копии директории postgresql-16.service.d."
    fi
else
    log_message "WARNING" "Директория postgresql-16.service.d не найдена."
fi

log_message "INFO" "Процесс резервного копирования завершен."

# Восстановления баз данных
for db in "${databases[@]}"; do
backup_file="$NFS_BACKUP_DIR/$DATE-${db}.backup"  # Убираем .gz

# Восстановление базы данных
if pg_restore -U postgres -C -d "postgres" -p 5433 -F c "$backup_file"; then
    log_message "INFO" "Резервная копия базы данных '$db' успешно восстановлена."
    # Удаляем базу данных после восстановления
    psql -U postgres -p 5433 -c "DROP DATABASE IF EXISTS $db;"
else
    log_message "ERROR" "Ошибка при восстановлении резервной копии базы данных '$db'."
    # Удаляем базу в случаае ошибки
    psql -U postgres -p 5433 -c "DROP DATABASE IF EXISTS $db;"
    # error_message="Ошибка при восстановлении базы данных '$db'"
    # send_email "$MAIL_SUBJECT" "$error_message"
    # send_telegram "$error_message"
fi
done

user_backup_file="$NFS_BACKUP_DIR/$DATE-users.sql"
temp_user_file="$NFS_BACKUP_DIR/temp_users.sql"

# Извлекаем пользователей из резервной копии
grep -E '^CREATE USER|^CREATE ROLE' "$user_backup_file" > "$temp_user_file"

# Проверяем и добавляем пользователей
while IFS= read -r line; do
    # Извлечение имени пользователя или роли
    # shellcheck disable=SC2076
    if [[ $line =~ '^CREATE (USER|ROLE) ([^;]+);' ]]; then
        username="${BASH_REMATCH[2]}"
        # Удаляем возможные кавычки вокруг имени
        username="${username#\"}"
        username="${username%\"}"

        # Проверка существования роли
        if ! psql -U postgres -p 5433 -tAc \"SELECT 1 FROM pg_roles WHERE rolname = \'$username\';\" | grep -q 1; then
            if psql -U postgres -p 5433 -c "$line"; then
                log_message "INFO" "Роль или пользователь '$username' успешно добавлен."
            else
                log_message "ERROR" "Ошибка при добавлении роли или пользователя '$username'."
            fi
        else
            log_message "INFO" "Роль или пользователь '$username' уже существует."
        fi
    fi
done < "$temp_user_file"

# Удаляем временный файл при выходе
trap 'rm -f "$temp_user_file"' EXIT

log_message "INFO" "Процесс восстановления резервных копий пользователей завершен."

# Функция для удаления старых резервных копий
cleanup_old_backups() {
    # Подсчет и удаление старых резервных копий, созданных более 1 дня назад
    old_backups_count=$(find "$BACKUP_DIR" -type f -mtime +1 -print -exec rm {} \; | wc -l)

    if [ $? -eq 0 ]; then
        log_message "INFO" "Старые резервные копии, созданные более дня назад, успешно удалены. Удалено файлов: $old_backups_count."
    else
        log_message "ERROR" "Ошибка при удалении старых резервных копий."
    fi
}

# Удаление старых резервных копий на NFS-шаре (старше 23 ч. 20 мин.) только если все резервные копии успешны
if [ "$backup_success" = true ]; then
    cleanup_old_backups
else
    log_message "WARNING" "Не удалены старые резервные копии, так как не все резервные копии были созданы успешно."
fi

log_message "INFO" "Процесс резервного копирования завершен."
