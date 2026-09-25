#!/bin/bash
# container-watchdog.sh 的隔离验证样例（只读 + 隔离目录，不碰生产文件）
set -u
D=/tmp/wd-drill
PROD_DIR=${PROD_DIR:-/path/to/docker}   # 生产部署目录（换成你自己的）
echo "=== 1. 语法检查 bash -n ==="
if bash -n /tmp/wd.sh; then echo "SYNTAX-OK"; else echo "SYNTAX-FAIL"; fi
echo
echo "=== 2. 隔离演练（BASE_DIR=$D；保活清单显式置空；网络段 dry-run）==="
rm -rf "$D"; mkdir -p "$D"
env WATCHDOG_BASE_DIR="$D" WATCHDOG_CONTAINERS= NET_HEAL_DRY=yes bash /tmp/wd.sh
echo "run1 rc=$?"
echo
echo "--- 产物 ---"
ls -l "$D" 2>&1
echo "--- 心跳 ---"; cat "$D/container-watchdog.heartbeat" 2>&1
echo "--- 日志 ---"; cat "$D/container-watchdog.log" 2>&1
echo "--- network state ---"; cat "$D/network-alert.state" 2>&1
echo
echo "=== 3. 生产文件是否被动过（mtime 应为演练前的旧值，脚本 run 时间=现在）==="
date '+now=%F %T'
stat -c '%y %n' "$PROD_DIR/storage-alert.state" "$PROD_DIR/napcat-alert.state" 2>&1
echo
echo "=== 4. 再跑一轮（幂等性）==="
env WATCHDOG_BASE_DIR="$D" WATCHDOG_CONTAINERS= NET_HEAL_DRY=yes bash /tmp/wd.sh
echo "run2 rc=$?"
echo "日志行数=$(wc -l < "$D/container-watchdog.log")"
echo
echo "=== 5. 存储段开关验证（开着但探针不存在 -> 应报 probe-missing，且 dry 不发信）==="
rm -rf "$D"; mkdir -p "$D"
env WATCHDOG_BASE_DIR="$D" WATCHDOG_CONTAINERS= NET_HEAL_DRY=yes STORAGE_ENABLED=yes MAIL_DRY=yes bash /tmp/wd.sh
echo "run3 rc=$?"
echo "--- 日志 ---"; cat "$D/container-watchdog.log" 2>&1
echo "--- storage state ---"; cat "$D/storage-alert.state" 2>&1
echo "=== done ==="
