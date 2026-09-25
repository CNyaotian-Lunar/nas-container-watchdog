#!/bin/bash
# 三件套的真机验证（隔离、只读；不回显任何设备标识）
set -u
D=/tmp/wd-verify; rm -rf "$D"; mkdir -p "$D"
echo "=== 1. python 语法编译 ==="
if python3 -m py_compile /tmp/probe.py /tmp/mail.py; then echo "COMPILE-OK"; else echo "COMPILE-FAIL"; fi
echo
echo "=== 2. 探针正对照：健康假 JSON（期望 rc=0 且零输出）==="
cat > "$D/ok.json" <<'EOF'
{"pools":{"pool":{"name":"pool","state":"ONLINE","error_count":0,"vdevs":{"0":{"name":"raidz2-0","guid":"g1","state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0,"vdevs":{"a":{"name":"sda","guid":"g2","state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0}}}},"l2cache":{"c":{"name":"nvme0n1","guid":"g3","state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0}},"scan_stats":{"function":"SCRUB","state":"FINISHED","errors":0}}}}
EOF
python3 /tmp/probe.py "$D/ok.json"; echo "rc=$?"
echo
echo "=== 3. 探针负对照：池仍 ONLINE 但 L2ARC FAULTED + 3 个读错误（应只报 L2ARC，含 ioerr 与 state 两条）==="
cat > "$D/bad.json" <<'EOF'
{"pools":{"pool":{"name":"pool","state":"ONLINE","error_count":0,"vdevs":{"0":{"name":"raidz2-0","guid":"g1","state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0}},"l2cache":{"c":{"name":"nvme0n1","guid":"g3","state":"FAULTED","read_errors":3,"write_errors":0,"checksum_errors":0}}}}}
EOF
python3 /tmp/probe.py "$D/bad.json"; echo "rc=$?"
echo
echo "=== 4. 探针负对照：池整体消失 / 空池（应报 no-pool）==="
echo '{"pools":{}}' > "$D/none.json"
python3 /tmp/probe.py "$D/none.json"; echo "rc=$?"
echo
echo "=== 5. --pool-list ==="
python3 /tmp/probe.py --pool-list "$D/ok.json"; echo "rc=$?"
echo
echo "=== 6. 真机只读：正常模式（只看退出码与输出行数，不回显内容）==="
out=$(python3 /tmp/probe.py); rc=$?
echo "rc=$rc 输出行数=$(printf '%s' "$out" | grep -c .)"
echo
echo "=== 7. mail.py：凭据文件不存在（期望 rc=1，且绝不发信）==="
env WATCHDOG_MAIL_ENV="$D/nope.env" python3 /tmp/mail.py "测试" - <<< "正文"; echo "rc=$?"
echo
echo "=== 8. mail.py：参数不足（期望 rc=2）==="
python3 /tmp/mail.py 2>/dev/null; echo "rc=$?"
echo
echo "=== 9. 清理 ==="
rm -rf "$D" /tmp/probe.py /tmp/mail.py /tmp/drill-verify.sh; rm -rf /tmp/__pycache__; echo CLEANED
echo "=== done ==="
