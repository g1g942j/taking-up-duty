#!/bin/bash
set -eo pipefail

echo "Начало создания бэкапа..."

LAST_RUN_TIMESTAMP=$(date +%s)
LAST_LOCAL_SUCCESS_TIMESTAMP=0
LAST_EXTERNAL_SUCCESS_TIMESTAMP=0

write_metric() {
    local tmp
    tmp=$(mktemp)

    local LOCAL_STATUS="$1"
    local EXTERNAL_STATUS="$2"
    local LAST_RUN_TS="$3"
    local LAST_LOCAL_SUCCESS_TS="$4"
    local LAST_EXTERNAL_SUCCESS_TS="$5"

    cat > "$tmp" <<EOF
# HELP local_backup_status Local backup status: 1 - success, 0 - failure
# TYPE local_backup_status gauge
local_backup_status ${LOCAL_STATUS}

# HELP external_backup_status Yandex disk backup status: 1 - success, 0 - failure
# TYPE external_backup_status gauge
external_backup_status ${EXTERNAL_STATUS}

# HELP backup_last_run_timestamp Last backup run time (unix timestamp)
# TYPE backup_last_run_timestamp gauge
backup_last_run_timestamp ${LAST_RUN_TS}

# HELP backup_last_local_success_timestamp Last successful local backup time (unix timestamp)
# TYPE backup_last_local_success_timestamp gauge
backup_last_local_success_timestamp ${LAST_LOCAL_SUCCESS_TS}

# HELP backup_last_external_success_timestamp Last successful external backup time (unix timestamp)
# TYPE backup_last_external_success_timestamp gauge
backup_last_external_success_timestamp ${LAST_EXTERNAL_SUCCESS_TS}

# HELP backup_age_seconds Age of last successful local backup
# TYPE backup_age_seconds gauge
backup_age_seconds $(( $(date +%s) - LAST_LOCAL_SUCCESS_TS ))
EOF

    chmod 644 "$tmp"
    mv "$tmp" /var/lib/node_exporter/textfile_collector/backup.prom
}

TIMESTAMP=$(TZ=Asia/Krasnoyarsk date +"%Y-%m-%d_%H-%M-%S")
DB_HOST="localhost"
DB_USER="postgres"
DB_NAME="project"
BACKUP_PATH="/opt/ganthedgehog/GantHedgehog/backup/dumps"
YANDEX_DISK_PATH="app:/GantHedgehogBackups"

source /opt/ganthedgehog/GantHedgehog/backup/secrets.conf

mkdir -p "$BACKUP_PATH"
BACKUP_FILE="$BACKUP_PATH/${TIMESTAMP}.sql.gz"



if pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" | gzip > "$BACKUP_FILE"; then
    :
else
    echo "Ошибка: не удалось создать бэкап"
    rm -f "$BACKUP_FILE"
    write_metric 0 0 "$LAST_RUN_TIMESTAMP" "$LAST_LOCAL_SUCCESS_TIMESTAMP" "$LAST_EXTERNAL_SUCCESS_TIMESTAMP"
    exit 1
fi



if [ ! -s "$BACKUP_FILE" ]; then
    echo "Ошибка: бэкап пустой"
    rm -f "$BACKUP_FILE"
    write_metric 0 0 "$LAST_RUN_TIMESTAMP" "$LAST_LOCAL_SUCCESS_TIMESTAMP" "$LAST_EXTERNAL_SUCCESS_TIMESTAMP"
    exit 1
fi



if gunzip -t "$BACKUP_FILE" > /dev/null 2>&1; then
    echo "Бэкап создан успешно"
    LAST_LOCAL_SUCCESS_TIMESTAMP=$(date +%s)
    write_metric 1 0 "$LAST_RUN_TIMESTAMP" "$LAST_LOCAL_SUCCESS_TIMESTAMP" "$LAST_EXTERNAL_SUCCESS_TIMESTAMP"
else
    echo "Ошибка: бэкап повреждён"
    rm -f "$BACKUP_FILE"
    write_metric 0 0 "$LAST_RUN_TIMESTAMP" "$LAST_LOCAL_SUCCESS_TIMESTAMP" "$LAST_EXTERNAL_SUCCESS_TIMESTAMP"
    exit 1
fi


curl -X PUT -H "Authorization: OAuth ${YANDEX_DISK_TOKEN}" \
    "https://cloud-api.yandex.net/v1/disk/resources?path=${YANDEX_DISK_PATH}" >/dev/null



UPLOAD_URL=$(curl -s -X GET \
    -H "Authorization: OAuth ${YANDEX_DISK_TOKEN}" \
    "https://cloud-api.yandex.net/v1/disk/resources/upload?path=${YANDEX_DISK_PATH}/${TIMESTAMP}.sql.gz&overwrite=true" \
    | jq -r '.href')



if [ -n "$UPLOAD_URL" ]; then
    if curl -T $BACKUP_FILE -H "Authorization: OAuth ${YANDEX_DISK_TOKEN}" "$UPLOAD_URL" >/dev/null; then
        echo "Резервная копия успешно отправлена на Яндекс.Диск"
        LAST_EXTERNAL_SUCCESS_TIMESTAMP=$(date +%s)
        write_metric 1 1 "$LAST_RUN_TIMESTAMP" "$LAST_LOCAL_SUCCESS_TIMESTAMP" "$LAST_EXTERNAL_SUCCESS_TIMESTAMP"
    else
        echo "Ошибка: не удалось загрузить файл"
        write_metric 1 0 "$LAST_RUN_TIMESTAMP" "$LAST_LOCAL_SUCCESS_TIMESTAMP" "$LAST_EXTERNAL_SUCCESS_TIMESTAMP"
        exit 1
    fi
else
    echo "Ошибка: не удалось получить URL загрузки"
    write_metric 1 0 "$LAST_RUN_TIMESTAMP" "$LAST_LOCAL_SUCCESS_TIMESTAMP" "$LAST_EXTERNAL_SUCCESS_TIMESTAMP"
    exit 1
fi


find "$BACKUP_PATH" -type f -mtime +7 -name "*.sql.gz" -delete

echo "Бэкап завершён успешно"
