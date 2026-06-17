#!/bin/bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <ip> <port>"
  echo "Example: $0 192.168.100.11 30620"
  exit 1
fi

BASE="http://$1:$2"
PASS=0
FAIL=0

check() {
  local label="$1"
  local method="$2"
  local url="$3"
  local expected="$4"
  local data="${5:-}"

  if [ -n "$data" ]; then
    actual=$(curl -s -o /tmp/check_body -w "%{http_code}" -X "$method" \
      -H "Content-Type: application/json" -d "$data" --max-time 5 "$url" 2>/dev/null || echo "000")
  else
    actual=$(curl -s -o /tmp/check_body -w "%{http_code}" -X "$method" \
      --max-time 5 "$url" 2>/dev/null || echo "000")
  fi

  body=$(cat /tmp/check_body 2>/dev/null || echo "")

  if [ "$actual" = "$expected" ]; then
    echo "  PASS  [$method] $label: HTTP $actual  $body"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  [$method] $label: expected HTTP $expected, got HTTP $actual  $body"
    FAIL=$((FAIL + 1))
  fi

  echo "$body"
}

echo "=== Проверка $BASE ==="
echo ""

echo "--- Health ---"
check "liveness"  GET "$BASE/healthz" 200 > /dev/null
check "readiness" GET "$BASE/readyz"  200 > /dev/null

echo ""
echo "--- CRUD ---"
body=$(check "создать заметку 1" POST "$BASE/notes" 201 '{"title":"test note","body":"hello world"}')
NOTE_ID=$(echo "$body" | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | head -1)

check "создать заметку 2"        POST   "$BASE/notes"          201 '{"title":"second note","body":"test body"}' > /dev/null
check "список заметок"           GET    "$BASE/notes"          200 > /dev/null
check "получить заметку"         GET    "$BASE/notes/$NOTE_ID" 200 > /dev/null
check "обновить заметку"         PUT    "$BASE/notes/$NOTE_ID" 200 '{"title":"updated","body":"updated body"}' > /dev/null
check "получить обновлённую"     GET    "$BASE/notes/$NOTE_ID" 200 > /dev/null
check "удалить заметку"          DELETE "$BASE/notes/$NOTE_ID" 200 > /dev/null
check "получить удалённую (404)" GET    "$BASE/notes/$NOTE_ID" 404 > /dev/null

echo ""
echo "--- Metrics ---"
check "prometheus metrics" GET "$BASE/metrics" 200 > /dev/null

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="
[ "$FAIL" -eq 0 ]
