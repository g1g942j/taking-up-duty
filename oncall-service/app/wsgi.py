"""WSGI entrypoint for gunicorn: gunicorn -w 4 -b 0.0.0.0:8080 wsgi:app"""
from app import app, bootstrap

bootstrap()
