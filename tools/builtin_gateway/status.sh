#!/bin/bash
# 查看内置模型服务状态：进程、公网地址、健康检查、双端配置版本、配额
set -euo pipefail

STATE_DIR="${QNOTE_STATE_DIR:-$HOME/.config/qnote-tunnel}"
GATEWAY_CONFIG="$STATE_DIR/gateway.json"
URL_FILE="$STATE_DIR/url.txt"

echo "== 进程 =="
for name in gateway cloudflared; do
  pid_file="$STATE_DIR/$name.pid"
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "  $name: 运行中（pid $(cat "$pid_file")）"
  else
    echo "  $name: 未运行"
  fi
done

echo
echo "== 隧道 =="
URL="$(cat "$URL_FILE" 2>/dev/null || true)"
if [ -n "$URL" ]; then
  echo "  $URL"
else
  echo "  未记录地址"
fi

echo
echo "== 健康检查 =="
HEALTH="$(curl -s -m 5 http://127.0.0.1:3426/health 2>/dev/null || true)"
if [ -n "$HEALTH" ]; then
  echo "  $HEALTH"
else
  echo "  /health 不可达"
fi

echo
echo "== 远程配置 =="
GITEE_API='https://gitee.com/api/v5/repos/favo9/qnote/contents/qnote_builtin.json?ref=builtin-config'
GITHUB_RAW="https://raw.githubusercontent.com/favoroo/QNote/builtin-config/qnote_builtin.json?t=$(date +%s)"
for entry in "Gitee API|$GITEE_API" "GitHub|$GITHUB_RAW"; do
  name="${entry%%|*}"
  url="${entry#*|}"
  body="$(curl -s -m 10 "$url" 2>/dev/null || true)"
  summary="$(printf '%s' "$body" | python3 -c "import json,sys,base64
try:
    d=json.loads(sys.stdin.read())
    if isinstance(d,dict) and d.get('encoding')=='base64' and d.get('content'):
        d=json.loads(base64.b64decode(d['content']).decode('utf-8'))
    print('v%s  %s  enabled=%s  image=%s' % (d.get('version'), d.get('chat',{}).get('baseUrl','?'), d.get('enabled'), d.get('image',{}).get('enabled')))
except Exception:
    print('不可读')" 2>/dev/null || echo '不可读')"
  echo "  $name: $summary"
done

echo
echo "== 本地配置 =="
if [ -f "$GATEWAY_CONFIG" ]; then
  python3 - "$GATEWAY_CONFIG" "$STATE_DIR/config-version" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    cfg = json.load(f)
q = cfg.get('quotas', {})
d = q.get('device', {})
print('  版本文件: v%s' % (open(sys.argv[2]).read().strip() if len(sys.argv) > 2 else '?'))
print('  设备额度: %s 次/小时, %s 次/天, %s tokens/天' % (d.get('perHour'), d.get('perDay'), d.get('tokensPerDay')))
print('  生图额度: %s 张/天/设备' % q.get('imageDevice', {}).get('perDay'))
print('  维护模式: %s' % cfg.get('maintenance', {}).get('enabled'))
print('  签名校验: %s' % cfg.get('requireSignature'))
PY
else
  echo "  缺少 gateway.json"
fi

echo
echo "== 最近用量 =="
if [ -f "$STATE_DIR/usage.jsonl" ]; then
  tail -5 "$STATE_DIR/usage.jsonl"
else
  echo "  暂无记录"
fi