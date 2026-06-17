#!/bin/bash
set -e

REDIS_DIR="/opt/taking-up-duty/redis-cluster"
CONFIG_DIR="$REDIS_DIR/config"
DATA_DIR="/var/lib/redis-cluster"

echo "Создание директорий для данных..."
for port in 7001 7002 7003 7004 7005 7006; do
  sudo mkdir -p "$DATA_DIR/redis-$port"
done

echo "Запуск Redis нод..."
for port in 7001 7002 7003 7004 7005 7006; do
  redis-server "$CONFIG_DIR/redis-$port.conf" --daemonize yes --logfile "/var/log/redis-$port.log"
  echo "  redis-$port запущен"
done

echo ""
echo "Ожидание поднятия нод..."
for port in 7001 7002 7003 7004 7005 7006; do
  until redis-cli -p $port ping 2>/dev/null | grep -q PONG; do
    echo "  Ожидание redis-$port..."
    sleep 1
  done
  echo "  redis-$port готов"
done

echo ""
echo "Создание Redis Cluster (3 masters + 3 replicas)..."
redis-cli --cluster create \
  127.0.0.1:7001 \
  127.0.0.1:7002 \
  127.0.0.1:7003 \
  127.0.0.1:7004 \
  127.0.0.1:7005 \
  127.0.0.1:7006 \
  --cluster-replicas 1 \
  --cluster-yes

echo ""
echo "Кластер создан. Cluster info:"
redis-cli -p 7001 cluster info
echo ""
echo "Cluster nodes:"
redis-cli -p 7001 cluster nodes
