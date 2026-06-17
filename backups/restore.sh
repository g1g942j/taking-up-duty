#!/bin/bash
set -eo pipefail



TIMESTAMP=$(TZ=Asia/Krasnoyarsk date +"%Y-%m-%d_%H-%M-%S")
DB_HOST="localhost"
DB_USER="service_user"
DB_NAME="notes"
BACKUP_PATH="/opt/taking-up-duty/backups/dumps"



if [ ! -d "$BACKUP_PATH" ] || [ -z "$(ls -A $BACKUP_PATH/*.sql.gz 2>/dev/null)" ]; then
        echo "Ошибка: файлы бэкапов отсутствуют"
        exit 1
fi



echo "Доступные бэкапы:"
ls -1 "$BACKUP_PATH"/*.sql.gz | nl -s ') '

read -p "Введите номер бэкапа для восстановления: " num
BACKUP_FILE=$(ls "$BACKUP_PATH"/*.sql.gz | sed -n "${num}p")

if [ -z "$BACKUP_FILE" ]; then
	echo "Неверный номер бэкапа"
	exit 1
fi



sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" >/dev/null 2>&1


if gunzip -t "$BACKUP_FILE" >/dev/null 2>&1; then
	echo "Восстановление БД из $BACKUP_FILE..."
	gunzip -c "$BACKUP_FILE" | sudo -u postgres psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME"
	echo "БД успешно восстановлена"
else
	echo "Ошибка: не получилось восстановить БД из бэкапа"
	exit 1
fi
