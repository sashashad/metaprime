#!/bin/bash

# Директория резервного копирования
BACKUP_DIR="/opt/backups/base/"

# Файл для логирования
LOG_FILE="/var/log/backup.log"

# Функция для логирования
log_message() {
    local level="$1"
    local message="$2"

    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$LOG_FILE"
}

# Получение списка баз данных
databases=$(psql -qAt -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

# Список баз данных для исключения
excluded_databases=("fias" "gisjkh" "postgres")

# Флаг для отслеживания успешного создания резервных копий
backup_successful=true

# Создание резервных копий каждой базы данных
for db in $databases; do
    # Проверка на исключение баз данных
    if [[ " ${excluded_databases[*]} " == *" $db "* ]]; then
        log_message "INFO" "База данных '$db' исключена из резервного копирования."
        continue
    fi

    pg_dump -F c -Z9 -b -v -f "$BACKUP_DIR/$(date +%d-%m-%Y)-$db.backup" "$db"
    if [ $? -eq 0 ]; then
        log_message "INFO" "Резервная копия базы данных '$db' успешно создана."
    else
        log_message "ERROR" "Ошибка при создании резервной копии базы данных '$db'."
        backup_successful=false  # Установить флаг в false, если резервное копирование не удалось
    fi
done

# Функция для удаления старых резервных копий
cleanup_old_backups() {
    # Подсчет и удаление старых резервных копий, созданных более 5 дней назад
    old_backups_count=$(find "$BACKUP_DIR" -type f -mtime +5 -print -exec rm {} \; | wc -l)

    if [ $? -eq 0 ]; then
        log_message "INFO" "Старые резервные копии, созданные более 5 дней назад, успешно удалены. Удалено файлов: $old_backups_count."
    else
        log_message "ERROR" "Ошибка при удалении старых резервных копий."
    fi
}

# Вызов функции очистки старых резервных копий, если были созданы успешные резервные копии
if [ "$backup_successful" = true ]; then
    cleanup_old_backups
else
    log_message "INFO" "Резервные копии не были созданы, очистка старых резервных копий не требуется."
fi

tar -czvf /opt/backups/configs/"`date +%d-%m-%Y`"-postgresql_configs.tar.gz /etc/postgresql/14/main &&
tar -czvf /opt/backups/configs/"`date +%d-%m-%Y`"-pgbouncer_configs.tar.gz /etc/pgbouncer &&
tar -czvf /opt/backups/configs/"`date +%d-%m-%Y`"-signers_jcp_jdk_configs.tar.gz /opt/registerx/jcp/ &&
cp -v /opt/postgresql/.bash_history /opt/backups/configs/ &&
cp -v /opt/postgresql/.psql_history /opt/backups/configs/ &&
find "/opt/backups/configs" -type f -mtime +5 -exec rm {} \;
