"""
On-call Readiness Service
--------------------------
Минимальный веб-сервис для лабораторной работы по развёртыванию и мониторингу.

Что внутри (специально, чтобы было что разворачивать и мониторить):
  * CRUD над сущностью "note" в PostgreSQL
  * кэш в Redis с TTL и fallback в БД при промахе/недоступности кэша
  * /metrics  — RED-метрики в формате Prometheus
  * /healthz  — liveness (процесс жив)
  * /readyz   — readiness (БД доступна)

Намеренно НЕ сделано (это часть задания студента):
  * нет готовых дашбордов, алертов, бэкапов, деплоя — всё это разворачивает студент.

Конфигурация — через переменные окружения (см. .env.example).
"""
import os
import time
import logging
from logging.handlers import RotatingFileHandler

import psycopg2
import psycopg2.pool
import redis
import redis.cluster
from flask import Flask, request, jsonify, Response

# --------------------------------------------------------------------------- #
# Конфигурация
# --------------------------------------------------------------------------- #
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "notes")
DB_USER = os.getenv("DB_USER", "notes")
DB_PASSWORD = os.getenv("DB_PASSWORD", "notes")

REDIS_TTL = int(os.getenv("REDIS_TTL", "30"))

_raw_nodes = os.getenv("REDIS_NODES", "localhost:7001")
REDIS_STARTUP_NODES = [
    redis.cluster.ClusterNode(h, int(p))
    for h, p in (node.split(":") for node in _raw_nodes.split(","))
]

APP_PORT = int(os.getenv("APP_PORT", "8080"))
LOG_DIR = os.getenv("LOG_DIR", "/var/log/oncall-service")

# --------------------------------------------------------------------------- #
# Логирование: пишем в файл (для logrotate) и в stdout (для kubectl logs)
# --------------------------------------------------------------------------- #
os.makedirs(LOG_DIR, exist_ok=True)
logger = logging.getLogger("oncall")
logger.setLevel(logging.INFO)
_fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")

_file = RotatingFileHandler(os.path.join(LOG_DIR, "app.log"),
                            maxBytes=10 * 1024 * 1024, backupCount=3)
_file.setFormatter(_fmt)
logger.addHandler(_file)

_stream = logging.StreamHandler()
_stream.setFormatter(_fmt)
logger.addHandler(_stream)

# --------------------------------------------------------------------------- #
# Метрики (RED: Rate, Errors, Duration) — без внешних зависимостей
# --------------------------------------------------------------------------- #
_metrics = {
    "requests_total": {},        # {(method, path, status): count}
    "request_duration_sum": {},  # {(method, path): seconds}
    "request_duration_count": {},
    "cache_hits_total": 0,
    "cache_misses_total": 0,
    "db_errors_total": 0,
}


def _track(method, path, status, duration):
    key = (method, path, str(status))
    _metrics["requests_total"][key] = _metrics["requests_total"].get(key, 0) + 1
    dkey = (method, path)
    _metrics["request_duration_sum"][dkey] = _metrics["request_duration_sum"].get(dkey, 0.0) + duration
    _metrics["request_duration_count"][dkey] = _metrics["request_duration_count"].get(dkey, 0) + 1


# --------------------------------------------------------------------------- #
# Подключения к зависимостям
# --------------------------------------------------------------------------- #
db_pool = None
rds = None


def init_db_pool():
    global db_pool
    db_pool = psycopg2.pool.SimpleConnectionPool(
        1, 10,
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD,
        connect_timeout=3,
    )


def init_schema():
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS notes (
                    id    SERIAL PRIMARY KEY,
                    title TEXT NOT NULL,
                    body  TEXT NOT NULL DEFAULT ''
                );
            """)
        conn.commit()
    finally:
        db_pool.putconn(conn)


def init_redis():
    global rds
    rds = redis.cluster.RedisCluster(
        startup_nodes=REDIS_STARTUP_NODES,
        decode_responses=True,
        socket_connect_timeout=1,
        socket_timeout=1,
        skip_full_coverage_check=True,
    )


app = Flask(__name__)


# --------------------------------------------------------------------------- #
# Хуки для измерения длительности всех запросов
# --------------------------------------------------------------------------- #
@app.before_request
def _start_timer():
    request._start = time.time()


@app.after_request
def _record(resp):
    dur = time.time() - getattr(request, "_start", time.time())
    # нормализуем путь: /notes/5 -> /notes/:id, чтобы не плодить кардинальность
    path = request.path
    parts = path.split("/")
    norm = "/".join(":id" if p.isdigit() else p for p in parts) or "/"
    _track(request.method, norm, resp.status_code, dur)
    return resp


# --------------------------------------------------------------------------- #
# Бизнес-логика: чтение с кэшем и fallback в БД
# --------------------------------------------------------------------------- #
def get_note(note_id):
    """Сначала кэш, при промахе/недоступности Redis — БД (fallback)."""
    cache_key = f"note:{note_id}"
    # 1. пробуем кэш; если Redis недоступен — НЕ падаем, идём в БД
    try:
        cached = rds.get(cache_key)
        if cached is not None:
            _metrics["cache_hits_total"] += 1
            title, body = cached.split("\x1f", 1)
            return {"id": note_id, "title": title, "body": body, "source": "cache"}
        _metrics["cache_misses_total"] += 1
    except redis.RedisError as e:
        logger.warning("redis unavailable, fallback to db: %s", e)

    # 2. идём в БД
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT title, body FROM notes WHERE id = %s", (note_id,))
            row = cur.fetchone()
    finally:
        db_pool.putconn(conn)

    if row is None:
        return None
    title, body = row
    # 3. пытаемся прогреть кэш с TTL; недоступность Redis не критична
    try:
        rds.setex(cache_key, REDIS_TTL, f"{title}\x1f{body}")
    except redis.RedisError as e:
        logger.warning("redis setex failed: %s", e)
    return {"id": note_id, "title": title, "body": body, "source": "db"}


def invalidate(note_id):
    try:
        rds.delete(f"note:{note_id}")
    except redis.RedisError:
        pass


# --------------------------------------------------------------------------- #
# CRUD-эндпоинты
# --------------------------------------------------------------------------- #
@app.post("/notes")
def create_note():
    data = request.get_json(silent=True) or {}
    title = data.get("title")
    if not title:
        return jsonify({"error": "title is required"}), 400
    body = data.get("body", "")
    try:
        conn = db_pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("INSERT INTO notes (title, body) VALUES (%s, %s) RETURNING id",
                            (title, body))
                new_id = cur.fetchone()[0]
            conn.commit()
        finally:
            db_pool.putconn(conn)
    except psycopg2.Error as e:
        _metrics["db_errors_total"] += 1
        logger.error("db error on create: %s", e)
        return jsonify({"error": "database error"}), 500
    return jsonify({"id": new_id, "title": title, "body": body}), 201


@app.get("/notes/<int:note_id>")
def read_note(note_id):
    try:
        note = get_note(note_id)
    except psycopg2.Error as e:
        _metrics["db_errors_total"] += 1
        logger.error("db error on read: %s", e)
        return jsonify({"error": "database error"}), 500
    if note is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(note)


@app.put("/notes/<int:note_id>")
def update_note(note_id):
    data = request.get_json(silent=True) or {}
    try:
        conn = db_pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("UPDATE notes SET title = COALESCE(%s, title), "
                            "body = COALESCE(%s, body) WHERE id = %s",
                            (data.get("title"), data.get("body"), note_id))
                updated = cur.rowcount
            conn.commit()
        finally:
            db_pool.putconn(conn)
    except psycopg2.Error as e:
        _metrics["db_errors_total"] += 1
        logger.error("db error on update: %s", e)
        return jsonify({"error": "database error"}), 500
    if updated == 0:
        return jsonify({"error": "not found"}), 404
    invalidate(note_id)
    return jsonify({"status": "updated", "id": note_id})


@app.delete("/notes/<int:note_id>")
def delete_note(note_id):
    try:
        conn = db_pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("DELETE FROM notes WHERE id = %s", (note_id,))
                deleted = cur.rowcount
            conn.commit()
        finally:
            db_pool.putconn(conn)
    except psycopg2.Error as e:
        _metrics["db_errors_total"] += 1
        logger.error("db error on delete: %s", e)
        return jsonify({"error": "database error"}), 500
    if deleted == 0:
        return jsonify({"error": "not found"}), 404
    invalidate(note_id)
    return jsonify({"status": "deleted", "id": note_id})


@app.get("/notes")
def list_notes():
    try:
        conn = db_pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT id, title FROM notes ORDER BY id")
                rows = cur.fetchall()
        finally:
            db_pool.putconn(conn)
    except psycopg2.Error as e:
        _metrics["db_errors_total"] += 1
        logger.error("db error on list: %s", e)
        return jsonify({"error": "database error"}), 500
    return jsonify([{"id": r[0], "title": r[1]} for r in rows])


# --------------------------------------------------------------------------- #
# Health / readiness
# --------------------------------------------------------------------------- #
@app.get("/healthz")
def healthz():
    # liveness: процесс жив и отвечает
    return jsonify({"status": "ok"})


@app.get("/readyz")
def readyz():
    # readiness: есть ли связь с БД (без БД сервис бесполезен)
    try:
        conn = db_pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        finally:
            db_pool.putconn(conn)
    except psycopg2.Error:
        return jsonify({"status": "db unavailable"}), 503
    return jsonify({"status": "ready"})


# --------------------------------------------------------------------------- #
# Prometheus-метрики
# --------------------------------------------------------------------------- #
@app.get("/metrics")
def metrics():
    lines = []
    lines.append("# HELP app_requests_total Total HTTP requests.")
    lines.append("# TYPE app_requests_total counter")
    for (method, path, status), count in _metrics["requests_total"].items():
        lines.append(f'app_requests_total{{method="{method}",path="{path}",status="{status}"}} {count}')

    lines.append("# HELP app_request_duration_seconds_sum Sum of request durations.")
    lines.append("# TYPE app_request_duration_seconds_sum counter")
    for (method, path), total in _metrics["request_duration_sum"].items():
        lines.append(f'app_request_duration_seconds_sum{{method="{method}",path="{path}"}} {total}')
    for (method, path), cnt in _metrics["request_duration_count"].items():
        lines.append(f'app_request_duration_seconds_count{{method="{method}",path="{path}"}} {cnt}')

    lines.append("# HELP app_cache_hits_total Cache hits.")
    lines.append("# TYPE app_cache_hits_total counter")
    lines.append(f'app_cache_hits_total {_metrics["cache_hits_total"]}')
    lines.append("# HELP app_cache_misses_total Cache misses.")
    lines.append("# TYPE app_cache_misses_total counter")
    lines.append(f'app_cache_misses_total {_metrics["cache_misses_total"]}')

    lines.append("# HELP app_db_errors_total Database errors.")
    lines.append("# TYPE app_db_errors_total counter")
    lines.append(f'app_db_errors_total {_metrics["db_errors_total"]}')

    return Response("\n".join(lines) + "\n", mimetype="text/plain")


# --------------------------------------------------------------------------- #
# Точка входа
# --------------------------------------------------------------------------- #
def bootstrap():
    init_db_pool()
    init_schema()
    init_redis()
    logger.info("service bootstrapped: db=%s:%s redis_nodes=%s",
                DB_HOST, DB_PORT, _raw_nodes)


if __name__ == "__main__":
    bootstrap()
    # dev-сервер; в "проде" студент должен поднять через gunicorn (см. README)
    app.run(host="0.0.0.0", port=APP_PORT)
