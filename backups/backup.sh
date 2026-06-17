#!/bin/bash
set -eo pipefail

echo "Начало создания бэкапа..."

TIMESTAMP=$(TZ=Asia/Krasnoyarsk date +"%Y-%m-%d_%H-%M-%S")
DB_HOST="localhost"
DB_USER="service_user"
DB_NAME="notes"
BACKUP_PATH="/opt/taking-up-duty/backups/dumps"

source /opt/taking-up-duty/backups/secrets.conf

mkdir -p "$BACKUP_PATH"
BACKUP_FILE="$BACKUP_PATH/${TIMESTAMP}.sql.gz"



if pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" | gzip > "$BACKUP_FILE"; then
    :
else
    echo "Ошибка: не удалось создать бэкап"
    rm -f "$BACKUP_FILE"
    exit 1
fi



if [ ! -s "$BACKUP_FILE" ]; then
    echo "Ошибка: бэкап пустой"
    rm -f "$BACKUP_FILE"
    exit 1
fi



if gunzip -t "$BACKUP_FILE" > /dev/null 2>&1; then
    echo "Бэкап создан успешно"
else
    echo "Ошибка: бэкап повреждён"
    rm -f "$BACKUP_FILE"
    exit 1
fi



find "$BACKUP_PATH" -type f -mtime +7 -name "*.sql.gz" -delete

echo "Бэкап завершён успешно"
