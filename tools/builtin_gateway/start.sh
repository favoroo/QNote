#!/bin/bash
# 启动 QNote 内置模型服务：本地网关 + Cloudflare 快速隧道 + 远程配置发布
# 幂等：网关/隧道已在跑时复用；URL 未变化时默认跳过发布（--publish 可强制）
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DIR/../.." && pwd)"
STATE_DIR="${QNOTE_STATE_DIR:-$HOME/.config/qnote-tunnel}"
ENV_FILE="$STATE_DIR/publish.env"
GATEWAY_CONFIG="$STATE_DIR/gateway.json"
GATEWAY_PID_FILE="$STATE_DIR/gateway.pid"
CF_PID_FILE="$STATE_DIR/cloudflared.pid"
URL_FILE="$STATE_DIR/url.txt"
FORCE_PUBLISH="${1:-}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令：$1" >&2
    exit 1
  }
}

need node
need cloudflared
need python3

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# 1) 预检 magpie：端口在听 + 局域网共享已开
if ! lsof -nP -iTCP:3425 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "magpie 没在 127.0.0.1:3425 监听，先启动 magpie。" >&2
  exit 1
fi
LAN_OK="$(python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.config/magpie/settings.json')));print('1' if d.get('lan') is True and str(d.get('lanKey','')).strip() else '0')" 2>/dev/null || echo 0)"
if [ "$LAN_OK" != "1" ]; then
  echo "magpie 的「Share on local network」未开启或缺少 lanKey：" >&2
  echo "  打开 magpie → Settings → Network and sharing → Share on local network" >&2
  exit 1
fi

# 2) 首次运行生成本地密钥；只存本机，不写仓库
if [ ! -f "$ENV_FILE" ]; then
  APP_SECRET="$(openssl rand -hex 32)"
  cat >"$ENV_FILE" <<EOF
QNOTE_APP_SECRET=$APP_SECRET
QNOTE_MIN_APP_VERSION=0.1.95
QNOTE_REQUIRE_SIGNATURE=false
EOF
  chmod 600 "$ENV_FILE"
  echo "已生成本地密钥：$ENV_FILE"
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# 3) 网关配置：不存在就复制模板，并把密钥/开关写进去
if [ ! -f "$GATEWAY_CONFIG" ]; then
  cp "$DIR/config.example.json" "$GATEWAY_CONFIG"
  chmod 600 "$GATEWAY_CONFIG"
fi
python3 - "$GATEWAY_CONFIG" "${QNOTE_APP_SECRET:-}" "${QNOTE_REQUIRE_SIGNATURE:-true}" "${QNOTE_MAINTENANCE:-}" "${QNOTE_IMAGE_ENABLED:-}" "${QNOTE_MAINTENANCE_MESSAGE:-}" <<'PY'
import json, sys
path, secret, require_sig, maintenance, image_enabled, maintenance_message = sys.argv[1:7]
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
if secret:
    cfg['appSecrets'] = [secret]
cfg['requireSignature'] = str(require_sig).lower() != 'false'
if maintenance:
    cfg.setdefault('maintenance', {})['enabled'] = str(maintenance).lower() == 'true'
if maintenance_message:
    cfg.setdefault('maintenance', {})['message'] = maintenance_message
if image_enabled and 'qnote-image-free' in cfg.get('models', {}):
    cfg['models']['qnote-image-free']['enabled'] = str(image_enabled).lower() == 'true'
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY

# 4) 启动网关
if [ -f "$GATEWAY_PID_FILE" ] && kill -0 "$(cat "$GATEWAY_PID_FILE")" 2>/dev/null; then
  echo "网关已在运行（pid $(cat "$GATEWAY_PID_FILE")）"
else
  rm -f "$GATEWAY_PID_FILE"
  nohup node "$DIR/server.js" --config "$GATEWAY_CONFIG" >"$STATE_DIR/gateway.log" 2>&1 &
  echo $! >"$GATEWAY_PID_FILE"
  echo "网关启动中（pid $(cat "$GATEWAY_PID_FILE")）"
fi
for _ in $(seq 1 20); do
  if curl -sf -m 2 http://127.0.0.1:3426/health >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! curl -sf -m 3 http://127.0.0.1:3426/health >/dev/null 2>&1; then
  echo "网关健康检查失败，看 $STATE_DIR/gateway.log" >&2
  tail -20 "$STATE_DIR/gateway.log" >&2 || true
  exit 1
fi

# 5) 启动 Cloudflare 隧道
if [ -f "$CF_PID_FILE" ] && kill -0 "$(cat "$CF_PID_FILE")" 2>/dev/null; then
  echo "隧道已在运行（pid $(cat "$CF_PID_FILE")）"
else
  rm -f "$CF_PID_FILE"
  : >"$STATE_DIR/cloudflared.log"
  nohup cloudflared tunnel --url http://127.0.0.1:3426 --no-autoupdate >"$STATE_DIR/cloudflared.log" 2>&1 &
  echo $! >"$CF_PID_FILE"
  echo "隧道启动中（pid $(cat "$CF_PID_FILE")）"
fi

URL=""
for _ in $(seq 1 35); do
  URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$STATE_DIR/cloudflared.log" 2>/dev/null | head -1 || true)"
  [ -n "$URL" ] && break
  sleep 1
done
if [ -z "$URL" ]; then
  echo "隧道地址还没出来，看 $STATE_DIR/cloudflared.log" >&2
  tail -20 "$STATE_DIR/cloudflared.log" >&2 || true
  exit 1
fi

OLD_URL="$(cat "$URL_FILE" 2>/dev/null || true)"
printf '%s\n' "$URL" >"$URL_FILE"

# 6) 发布远程配置：URL 变化或显式要求时
if [ "$OLD_URL" != "$URL" ] || [ "$FORCE_PUBLISH" = "--publish" ] || [ "$FORCE_PUBLISH" = "--force" ]; then
  bash "$DIR/publish.sh" --base-url "$URL" | tee "$STATE_DIR/last-publish.log"
else
  echo "URL 未变化，跳过发布（加 --publish 可强制重发）"
fi

# 7) 汇总
VERSION="$(cat "$STATE_DIR/config-version" 2>/dev/null || echo '?')"
printf '\n'
printf '公网地址 : %s\n' "$URL"
printf 'Base URL : %s/v1\n' "$URL"
printf '配置版本 : v%s\n' "$VERSION"
printf '健康检查 : %s\n' "$(curl -s -m 5 http://127.0.0.1:3426/health)"
printf 'App 签名 : QNOTE_BUILTIN_APP_SECRET 的值见 %s\n' "$ENV_FILE"
printf '本地联调 : flutter run ... --dart-define=QNOTE_BUILTIN_APP_SECRET=<见上文件>\n'