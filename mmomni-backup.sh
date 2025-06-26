#!/bin/bash

# =================================================================
# Скрипт автоматического резервного копирования системы Mattermost
# =================================================================
#
# Описание:
#   Создает резервную копию системы с помощью утилиты mmomni,
#   ведет журнал операций и автоматически удаляет старые резервные копии
#
# Использование:
#   ./script_name.sh
#
# Требования:
#   - Установленная утилита mmomni
#   - Права на запись в директории BACKUP_DIR и LOG_DIR
#
# Настройки:
#   BACKUP_DIR - директория для хранения резервных копий
#   LOG_DIR    - директория для хранения логов
#   DAYS_TO_KEEP - количество дней хранения резервных копий и логов
#
# Формат выходных файлов:
#   Бэкапы: mm_YYYYMMDD.backup
#   Логи: backup_YYYYMMDD.log
#
# Автор: [abakcheev]
# Дата создания: [20.01.2025]
# Версия: 1.0
#
# =================================================================

# Конфигурация
BACKUP_DIR="/backups"
LOG_DIR="/var/log/mattermost"
DAYS_TO_KEEP=7

# Создаем необходимые директории
mkdir -p $BACKUP_DIR
mkdir -p $LOG_DIR

# Задаем имена файлов
DATE=$(date +"%d%m%Y")
BACKUP_FILE="$BACKUP_DIR/mmomni-backup_$DATE.backup"
LOG_FILE="$LOG_DIR/mmomni-backup_$DATE.log"

# Функция логирования
log() {
    echo "$(date +"%d-%m-%Y %H:%M:%S") - $1" >> "$LOG_FILE"
}

# Начинаем бэкап
log "Starting backup..."

# Выполняем бэкап
mmomni backup -o "$BACKUP_FILE" 2>&1 | tee -a "$LOG_FILE"

# Проверяем успешность выполнения
if [ $? -eq 0 ]; then
    log "Backup completed successfully: $BACKUP_FILE"
else
    log "Backup failed!"
    exit 1
fi

# Удаляем старые бэкапы
log "Cleaning old backups..."
find $BACKUP_DIR -name "mmomni-backup_*.backup" -type f -mtime +$DAYS_TO_KEEP -delete
find $LOG_DIR -name "mmomni-backup_*.log" -type f -mtime +$DAYS_TO_KEEP -delete

log "Backup process completed"
