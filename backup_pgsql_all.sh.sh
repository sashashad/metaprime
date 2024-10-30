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
backup_date=$(date +%d-%m-%Y)

# Создание необходимых директорий для резервных копий
mkdir -p "$NFS_BACKUP_DIR/conf" "$NFS_BACKUP_DIR/service"

# Получаем список всех баз данных
databases=$(psql -U postgres -qAt -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

# Проверяем, удалось ли получить список баз данных
if [ -z "$databases" ]; then
    log_message "ERROR" "Не удалось получить список баз данных."
    exit 1
fi

# Список баз данных для резервного копирования
#databases=("ias_gorizont_filestorage")
databases=("ias_gorizont" "ias_gorizont_filestorage" "rosreestr_etl")

# Создание резервных копий каждой базы данных
backup_success=true

for db in "${databases[@]}"; do
    backup_file="$NFS_BACKUP_DIR/$backup_date-${db}.backup.gz"

    # Команда для создания резервной копии
    pg_dump -U postgres -F c -b -v "$db" | gzip > "$backup_file"

    # Проверка успешности выполнения команды
    if [ $? -eq 0 ]; then
        log_message "INFO" "Резервная копия базы данных '$db' успешно создана: $backup_file"
    else
        log_message "ERROR" "Ошибка при создании резервной копии базы данных '$db'."
        backup_success=false  # Установить флаг в false, если резервное копирование не удалось
    fi
done

# Удаление старых резервных копий на NFS-шаре (старше 23 ч. 20 мин.) только если все резервные копии успешны
if [ "$backup_success" = true ]; then
    deleted_files_count=$(find "$NFS_BACKUP_DIR" -type f -mmin +1400 -exec rm -f {} \; -print | wc -l)
    log_message "INFO" "Удалено старых резервных копий: $deleted_files_count"
else
    log_message "WARNING" "Не удалены старые резервные копии, так как не все резервные копии были созданы успешно."
fi

# Резервное копирование пользователей и их привилегий
user_backup_file="$NFS_BACKUP_DIR/$backup_date-users.sql"
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
    backup_path="$NFS_BACKUP_DIR/conf/$backup_date-${base_name}"
    cp "$config_file" "$backup_path"
    if [ $? -eq 0 ]; then
        log_message "INFO" "Резервная копия $base_name успешно создана в $backup_path."
    else
        log_message "ERROR" "Ошибка при создании резервной копии $base_name."
    fi
done

# Резервное копирование директории postgresql-16.service.d
service_dir="/etc/systemd/system/postgresql-16.service.d/"
service_backup_file="$NFS_BACKUP_DIR/service/$backup_date-postgresql-16.service.d.tar.gz"
if [ -d "$service_dir" ]; then
    if tar -czf "$service_backup_file" -C "$(dirname "$service_dir")" "$(basename "$service_dir")"; then
        log_message "INFO" "Резервная копия директории postgresql-16.service.d успешно создана: $service_backup_file"
    else
        log_message "ERROR" "Ошибка при создании резервной копии директории postgresql-16.service.d."
    fi
else
    log_message "WARNING" "Директория postgresql-16.service.d не найдена."
fi


# Удаление файлов из папок conf и service (старше 1 дня)
deleted_conf_service_count=$(find "$NFS_BACKUP_DIR/conf" "$NFS_BACKUP_DIR/service" "$NFS_BACKUP_DIR" -type f -mtime +1 -exec rm -f {} \; -print | wc -l)

if [ "$total_deleted_files_count" -gt 0 ]; then
    log_message "INFO" "Старые резервные копии на NFS-шаре успешно удалены. Удалено файлов: $deleted_conf_service_count."
else
    log_message "INFO" "Старых резервных копий для удаления не найдено."
fi

touch "$NFS_BACKUP_DIR/done.flag"

log_message "INFO" "Процесс резервного копирования завершен."