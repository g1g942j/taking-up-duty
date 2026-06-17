#!/bin/bash
set -e

echo "Ожидание поднятия Redis nodes..."
for port in 7001 7002 7003 7004 7005 7006; do
  until docker exec redis-${port} redis-cli -p ${port} ping 2>/dev/null | grep -q PONG; do
    echo "Ожидание redis-${port}..."
    sleep 1
  done
  echo "  redis-${port} запущен"
done

echo ""
echo "Создание Redis Cluster (3 masters + 3 replicas)..."

docker exec -it redis-7001 redis-cli --cluster create \
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
docker exec redis-7001 redis-cli -p 7001 cluster info
echo ""
echo "Cluster nodes:"
docker exec redis-7001 redis-cli -p 7001 cluster nodes
