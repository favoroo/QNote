#!/bin/bash
# 停止内置模型服务（不删除配置与用量记录）
set -euo pipefail

STATE_DIR="${QNOTE_STATE_DIR:-$HOME/.config/qnote-tunnel}"

for name in cloudflared gateway; do
  pid_file="$STATE_DIR/$name.pid"
  if [ -f "$pid_file" ]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo "已停止 $name（pid $pid）"
    else
      echo "$name 未在运行（残留 pid 文件已清理）"
    fi
    rm -f "$pid_file"
  else
    echo "$name 未在运行"
  fi
done