#!/bin/bash

# Функция вывода справки
usage() {
  echo "Использование: $0 -d <backup_date> -p <backup_path> [-T <db_prefix>] [-D <db_list>]"
  echo "  -d   Дата бэкапа (например, 28-01-2025)"
  echo "  -p   Путь до директории с бэкапами (например, /backups)"
  echo "  -T   Префикс для имени целевой базы данных (по умолчанию 'habar')"
  echo "  -D   Список баз данных через запятую (например, \"rx_authserver,rx_nsi,rx_registerx_log\")"
  exit 1
}

# Значения по умолчанию
DB_PREFIX="habar"
# Если список баз не передан, используем стандартный массив
DATABASES_DEFAULT=(
  "rx_authserver"
  "rx_nsi"
  "rx_registerx_log"
  "rx_registerx_main"
  "rx_registerx_objecthistory"
  "rx_registerx_staff"
  "rx_registerx_system"
  "rx_smev_adapter_main"
  "rx_smev_adapter_objecthistory"
  "rx_smev_adapter_system"
)

# Обработка параметров командной строки
while getopts ":d:p:T:D:" opt; do
  case ${opt} in
    d)
      BACKUP_DATE="${OPTARG}"
      ;;
    p)
      BACKUP_PATH="${OPTARG}"
      ;;
    T)
      DB_PREFIX="${OPTARG}"
      ;;
    D)
      DB_LIST="${OPTARG}"
      ;;
    ?)
      echo "Неверный параметр: -${OPTARG}" >&2
      usage
      ;;
    :)
      echo "Параметр -${OPTARG} требует аргумента." >&2
      usage
      ;;
  esac
done

# Проверка обязательных параметров
if [ -z "${BACKUP_DATE}" ] || [ -z "${BACKUP_PATH}" ]; then
  echo "Необходимо задать дату бэкапа и путь к директории с бэкапами." >&2
  usage
fi

# Если список баз данных передан, то формируем массив из переданной строки,
# иначе используем значения по умолчанию
if [ -n "${DB_LIST}" ]; then
  IFS=',' read -r -a DATABASES <<< "${DB_LIST}"
else
  DATABASES=("${DATABASES_DEFAULT[@]}")
fi

echo "Начинается восстановление баз данных."
echo "Дата бэкапа: ${BACKUP_DATE}"
echo "Директория с бэкапами: ${BACKUP_PATH}"
echo "Префикс для имен баз данных: ${DB_PREFIX}"
echo "Список баз для восстановления:"
printf '  %s\n' "${DATABASES[@]}"
echo

# Восстановление баз данных
for DB in "${DATABASES[@]}"; do
    # Формируем имя целевой базы данных с префиксом
    TARGET_DB="${DB_PREFIX}_${DB}"
    
    BACKUP_FILE="${BACKUP_PATH}/${BACKUP_DATE}-${DB}.backup"
    echo "Восстанавливаю базу данных '${TARGET_DB}' из файла '${BACKUP_FILE}'"
    
    # Выполняем восстановление (опция -C создаёт базу, если её нет)
    pg_restore -d "${TARGET_DB}" "${BACKUP_FILE}"
    
    if [ $? -ne 0 ]; then
        echo "Ошибка при восстановлении базы данных ${TARGET_DB}"
    else
        echo "База данных ${TARGET_DB} успешно восстановлена!"
    fi
    echo
done