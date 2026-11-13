#!/bin/bash
# 重新发布内置模型远程配置（版本 +1，双端并行推送）
# 用法：publish.sh [--base-url URL] [--dry-run] [--version N]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${QNOTE_STATE_DIR:-$HOME/.config/qnote-tunnel}"
ENV_FILE="$STATE_DIR/publish.env"
GATEWAY_CONFIG="$STATE_DIR/gateway.json"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

BASE_URL=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --base-url=*)
      BASE_URL="${1#--base-url=}"
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$BASE_URL" ]; then
  BASE_URL="$(cat "$STATE_DIR/url.txt" 2>/dev/null || true)"
fi
if [ -z "$BASE_URL" ]; then
  echo "没有可用的隧道地址：先启动服务，或传 --base-url" >&2
  exit 1
fi

exec env \
  QNOTE_STATE_DIR="$STATE_DIR" \
  QNOTE_GATEWAY_CONFIG="$GATEWAY_CONFIG" \
  QNOTE_BASE_URL="$BASE_URL" \
  node "$DIR/publish.js" ${ARGS[@]+"${ARGS[@]}"}