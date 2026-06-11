#!/usr/bin/env bash
# Генератор трафика для проверки RED-метрик и SLO-дашбордов.
# Использование: ./loadgen.sh [BASE_URL] [REQUESTS]
set -euo pipefail
BASE="${1:-http://localhost:8080}"
N="${2:-1000}"

echo "Seeding a note..."
ID=$(curl -s -X POST "$BASE/notes" -H 'Content-Type: application/json' \
     -d '{"title":"hello","body":"world"}' | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Created note id=$ID"

echo "Generating $N requests..."
for i in $(seq 1 "$N"); do
  curl -s -o /dev/null "$BASE/notes/$ID"
  if (( i % 50 == 0 )); then echo "  $i/$N"; fi
done
echo "Done."
