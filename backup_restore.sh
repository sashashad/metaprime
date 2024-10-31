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
    echo "Этот скрипт предназначен для восстановления резервных копий баз данных PostgreSQL с NFS-шары."
    echo
    echo "Перед использованием убедитесь, что NFS-шара доступна на целевом сервере с помощью команды \"showmount -e <nfs-server>\""
    echo
    echo "Аргументы:"
    echo "  <nfs_backup_dir>: Путь к NFS-шаре, где хранятся резервные копии."
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

# NFS-шара для резервных копий
nfs="$1"
backup_date=$(date +%d-%m-%Y)

# Список баз данных для восстановления
#databases=("ias_gorizont" "ias_gorizont_filestorage" "rosreestr_etl")
databases=("ias_gorizont_filestorage")

if [ -f "$nfs/done.flag" ]; then
     log_message "INFO" "Найден файл-флаг '$nfs/done.flag'."

     # Удалите файл-сигнал
     rm "$nfs/done.flag"

    for db in "${databases[@]}"; do
        backup_file="$nfs/$backup_date-${db}.backup"  # Убираем .gz

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

    user_backup_file="$nfs/$backup_date-users.sql"
    temp_user_file="$nfs/temp_users.sql"

    # Извлекаем пользователей из резервной копии
    grep -E '^CREATE USER|^CREATE ROLE' "$user_backup_file" > "$temp_user_file"

    # Проверяем и добавляем пользователей
    while IFS= read -r line; do
        # Извлечение имени пользователя или роли
        if [[ $line =~ \'^CREATE (USER|ROLE) ([^;]+);\' ]]; then
            username="${BASH_REMATCH[2]}"
            # Удаляем возможные кавычки вокруг имени
            username="${username#\"}"
            username="${username%\"}"
    
            # Проверка существования роли
            if ! psql -U postgres -p 5433 -tAc \"SELECT 1 FROM pg_roles WHERE rolname = \'$username\';\" | grep -q 1; then
                if psql -U postgres -p 5433 -c "$line/"; then
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
else
    log_message "WARNING" "Отсутствует файл-флаг '$nfs/done.flag'."
fi
