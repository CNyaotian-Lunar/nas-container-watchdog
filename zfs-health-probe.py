#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 本工具由 DeepSeek（DSH agent）编写，由 CNyaotian 维护与发布。
"""ZFS 存储健康探针（池 / vdev / L2ARC / SLOG / special / 诊断消息）

用法:
  zfs-health-probe.py                # 实时跑 `sudo -n /sbin/zpool status -j`
  zfs-health-probe.py <status.json>  # 读指定 JSON（演练/自测用，完全不碰真机）
  zfs-health-probe.py --selfcheck    # 打印被检查对象的基线清单（人眼核对用）
  zfs-health-probe.py --pool-list    # 只打印当前池名（供看门狗比对"期望池清单"基线）

输出: 每行 "<LEVEL>\t<SIGKEY>\t<消息>"，LEVEL ∈ {CRIT, WARN}；**无输出 = 全部健康**
  · SIGKEY 是**去重签名键**：只放"哪台设备/哪个池出了什么性质的问题"，
    **不放计数、进度、时间**——否则计数增长会让签名每轮都变，导致每 2 分钟一封告警信（风暴）。
  · 消息里保留真实计数，给人看。
退出码: 0 = 探测成功（有无异常都是 0）；2 = 探测失败（zpool 不可用 / JSON 解析失败）
        —— 探测失败必须让看门狗当成故障告警，否则存储故障会静默。

为什么要有它:
  · `zpool status` 文本解析易碎（缩进/tab/换行），ZFS 2.4 起有原生 `-j` JSON，直接吃结构。
  · **L2ARC(cache) 不在 pools[].vdevs 树里**，而是单独的 `l2cache` 字段；
    L2ARC 掉线时池 state 仍是 ONLINE —— 只看池 health 的巡检会静默漏报。
    同理 `special`(元数据 vdev) / `spares` / `logs` / `dedup` 也都是顶层独立键（实测发现）。
  · 正常状态：`ONLINE`，以及 **热备盘的 `AVAIL`（健康但未启用，不是故障）**；
    只有 `INUSE`（备盘顶上）与 DEGRADED/FAULTED/UNAVAIL/REMOVED/OFFLINE/SUSPENDED 才算异常。
  · scrub/resilver **不输出**：scan 真实状态串是 `NONE/SCANNING/FINISHED/CANCELED/ERRORSCRUBBING`
    （旧版用的判据已废弃，现以 scan 状态串为准）；进度数字每轮都变，一旦进签名就会刷屏。
    想看进度用 `--selfcheck` 或 `zpool status`。

字段随 ZFS 版本变化，升级后请跑 --selfcheck 抽验。
"""
import json
import os
import subprocess
import sys

ZPOOL = "/sbin/zpool"
# 正常状态：ONLINE + AVAIL（热备盘插着但未启用，属健康）
OK_STATES = ("ONLINE", "AVAIL")
# 顶层除 vdevs 外可能出现的"设备集合"字段
# （cache 段叫 l2cache；special 是元数据专用 vdev，实测证明它同样在顶层，不在 vdevs 树里）
EXTRA_SETS = (
    ("l2cache", "L2ARC 缓存盘"),
    ("special", "special 元数据 vdev"),
    ("spares", "热备盘"),
    ("logs", "SLOG 日志盘"),
    ("dedup", "去重盘"),
)
CLASS_LABEL = {
    "l2cache": "L2ARC 缓存盘",
    "special": "special 元数据 vdev",
    "log": "SLOG 日志盘",
    "spare": "热备盘",
    "dedup": "去重盘",
    "normal": "数据设备",
}


def as_int(v):
    """容错取整：取不到当 0（宁可少报也不要因为类型异常让整段崩掉）。"""
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return 0


def clean_key(s):
    """签名键里不能有 tab / 换行（会破坏分段）。"""
    return str(s).replace("\t", " ").replace("\n", " ").replace("\r", " ")


def label(node, fallback="设备"):
    cls = (node.get("class") or "").lower()
    vtype = (node.get("vdev_type") or "").lower()
    if cls in CLASS_LABEL:
        return CLASS_LABEL[cls]
    if vtype in ("raidz", "mirror", "draid"):
        return "vdev"
    return fallback


def walk(pool, node, out, seen):
    """递归遍历一个 vdev 节点（含其子 vdev）。"""
    if not isinstance(node, dict):
        return
    name = node.get("name") or "?"
    # v3：递归防御键改用 guid（实测发现按 (池,名字) 去重会吃掉同名节点）
    key = node.get("guid") or "%s/%s" % (pool, name)
    if key in seen:
        return
    seen.add(key)

    state = (node.get("state") or "").upper()
    rd = as_int(node.get("read_errors"))
    wr = as_int(node.get("write_errors"))
    ck = as_int(node.get("checksum_errors"))

    if state and state not in OK_STATES:
        out.append(("CRIT",
                    "state:%s:%s" % (clean_key(pool), clean_key(name)),
                    "池 %s：%s %s 状态 = %s" % (pool, label(node), name, state)))
    if rd or wr or ck:
        # 签名键**不含计数**：盘在缓慢恶化（1→2→3）不该每 2 分钟重发；同一台盘只报一次，
        # 消息里带最新计数，恢复时才发解除信。
        out.append(("CRIT",
                    "ioerr:%s:%s" % (clean_key(pool), clean_key(name)),
                    "池 %s：%s %s 有 I/O 错误（读 %d / 写 %d / 校验 %d）"
                    % (pool, label(node), name, rd, wr, ck)))

    for sub in (node.get("vdevs") or {}).values():
        walk(pool, sub, out, seen)


def scan_pool(pool, node, out):
    seen = set()
    name = node.get("name") or pool
    state = (node.get("state") or "").upper()
    if state and state not in OK_STATES:
        out.append(("CRIT", "state:%s" % clean_key(name),
                    "池 %s：整体状态 = %s" % (name, state)))

    ec = as_int(node.get("error_count"))
    if ec:
        out.append(("CRIT", "ec:%s" % clean_key(name),
                    "池 %s：error_count = %d（存在未清除的数据错误）" % (name, ec)))

    # v3：ZFS 自己的诊断消息（ERRATA / hostid mismatch / 版本或特性不兼容等）
    #     —— 这类问题池与 vdev 可能全是 ONLINE，只看 state 会整类漏掉。
    diag = node.get("status")
    act = node.get("action")
    if diag or act:
        mid = node.get("msgid") or "diag"
        parts = []
        if diag:
            parts.append("status: %s" % diag)
        if act:
            parts.append("action: %s" % act)
        if node.get("moreinfo"):
            parts.append("moreinfo: %s" % node["moreinfo"])
        out.append(("WARN", "poolmsg:%s:%s" % (clean_key(name), clean_key(mid)),
                    "池 %s：ZFS 诊断（msgid=%s）—— %s" % (name, mid, " ｜ ".join(parts))))

    if isinstance(node.get("vdevs"), dict):
        for sub in node["vdevs"].values():
            walk(name, sub, out, seen)

    # cache / special / log / spare / dedup 等顶层集合（L2ARC 就在这里！）
    for field, human in EXTRA_SETS:
        grp = node.get(field)
        if isinstance(grp, dict):
            for sub in grp.values():
                walk(name, sub, out, seen)

    # v3（对抗性审查）：结构异常防御 —— 池在、但一个 vdev / 顶层设备集合都没有时，
    #   遍历不到任何东西，绝不能因此当成"健康"。正常池至少有一个 root vdev。
    grp_exists = bool(node.get("vdevs")) or any(
        isinstance(node.get(f), dict) and node.get(f) for f, _ in EXTRA_SETS)
    if not grp_exists:
        out.append(("CRIT", "novdev:%s" % clean_key(name),
                    "池 %s：zpool status -j 里没有任何 vdev（池结构异常 / 未完全导入？请人工核对）" % name))

    scan = node.get("scan_stats")
    if isinstance(scan, dict):
        serr = as_int(scan.get("errors"))
        if serr:
            out.append(("CRIT", "scanerr:%s:%s" % (clean_key(name), scan.get("function") or "scan"),
                        "池 %s：最近一次 %s 报告 %d 个错误（%s）"
                        % (name, scan.get("function") or "scan", serr,
                           scan.get("end_time") or scan.get("state") or "")))
        # 注意：scan 进行中（SCANNING）故意不输出 —— 进度数字每轮都变，进签名就会刷屏


def collect(payload):
    out = []
    pools = payload.get("pools") or {}
    if not pools:
        out.append(("CRIT", "no-pool",
                    "zpool status -j 里没有任何池（ZFS 池全部未导入？）"))
        return out
    for name, node in pools.items():
        if isinstance(node, dict):
            scan_pool(name, node, out)
    return out


def selfcheck(payload):
    pools = payload.get("pools") or {}
    for name, node in pools.items():
        print("池 %s state=%s error_count=%s msgid=%s" % (
            name, node.get("state"), node.get("error_count"), node.get("msgid")))
        scan = node.get("scan_stats")
        if isinstance(scan, dict):
            print("  scan: %s state=%s errors=%s examined=%s" % (
                scan.get("function"), scan.get("state"), scan.get("errors"),
                scan.get("examined")))
        def walk2(n, d=1):
            if not isinstance(n, dict):
                return
            print("%s%s class=%s state=%s rd=%s wr=%s ck=%s" % (
                "  " * d, n.get("name"), n.get("class"), n.get("state"),
                n.get("read_errors"), n.get("write_errors"), n.get("checksum_errors")))
            for s in (n.get("vdevs") or {}).values():
                walk2(s, d + 1)
        for f, human in (("vdevs", "数据"),) + EXTRA_SETS:
            grp = node.get(f)
            if isinstance(grp, dict):
                print("  [%s]" % human)
                for s in grp.values():
                    walk2(s, 1)
    return 0


def load(path=None):
    """返回 (payload, err)；err 非空表示探测失败。"""
    if path:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                return json.load(fh), None
        except Exception as exc:  # noqa: BLE001
            return None, "读取/解析 %s 失败：%s" % (path, exc)
    if not os.path.exists(ZPOOL) or not os.access(ZPOOL, os.X_OK):
        return None, "找不到可执行的 %s" % ZPOOL
    try:
        proc = subprocess.run(["sudo", "-n", ZPOOL, "status", "-j"],
                              capture_output=True, timeout=60)
    except Exception as exc:  # noqa: BLE001
        return None, "执行 zpool status -j 失败：%s" % exc
    if proc.returncode != 0:
        detail = (proc.stderr or b"").decode("utf-8", "replace").strip()[:300]
        return None, "zpool status -j 退出码 %d：%s" % (proc.returncode, detail)
    try:
        return json.loads(proc.stdout.decode("utf-8", "replace")), None
    except Exception as exc:  # noqa: BLE001
        return None, "zpool status -j 输出不是合法 JSON：%s" % exc


def main():
    args = sys.argv[1:]
    paths = [a for a in args if not a.startswith("-")]
    path = paths[0] if paths else None
    payload, err = load(path)
    if err:
        sys.stdout.write("CRIT\tprobe-failed\t无法读取 ZFS 状态：%s\n" % err)
        return 2
    if "--selfcheck" in args:
        return selfcheck(payload)
    if "--pool-list" in args:
        for name in sorted((payload.get("pools") or {}).keys()):
            sys.stdout.write("%s\n" % name)
        return 0
    for level, sigkey, msg in collect(payload):
        sys.stdout.write("%s\t%s\t%s\n" % (level, sigkey, msg))
    return 0


if __name__ == "__main__":
    sys.exit(main())
