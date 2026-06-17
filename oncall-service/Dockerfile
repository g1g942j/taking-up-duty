FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_PORT=8080 \
    LOG_DIR=/var/log/oncall-service

WORKDIR /srv/oncall-service

RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin appuser \
    && mkdir -p "$LOG_DIR" \
    && chown -R appuser:appuser "$LOG_DIR"

COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
RUN chown -R appuser:appuser /srv/oncall-service

USER appuser

CMD ["sh", "-c", "gunicorn -w ${GUNICORN_WORKERS:-4} -b 0.0.0.0:$APP_PORT --chdir app wsgi:app"]
