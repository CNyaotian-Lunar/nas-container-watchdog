#!/bin/bash
# 本工具由 DeepSeek（DSH agent）编写，由 CNyaotian 维护与发布。
# =============================================================================
# container-watchdog.sh —— NAS 容器看门狗
#
# 干什么（四段，可各自开关）：
#   1) 容器保活：列表里的容器不是 running 就拉起来（不依赖 restart 策略语义；
#      Docker 的 live-restore + unless-stopped 有"手动停过就永不自启"的坑）
#   2) 证书热加载：acme 续期后，把用到证书的容器逐个重启（文件/内存缓存的缘故）
#   3) 告警发信：所有告警走 watchdog-mail.py（凭据放 watchdog-mail.env，权限 600）
#   4) 容器网络自愈：冷启动时宿主网络没就绪，dockerd 会登记网络端点却不建 veth，
#      容器里只剩 lo（表现为 Network is unreachable），且 docker restart 修不好
#      —— 只有 docker network connect 能重建。本段负责发现并挂回。
#
# 设计要点（都是踩过坑才有的，改动前请先读懂）：
#   · 去重签名只取「问题集合」，不含会持续变化的计数/进度 —— 否则每轮一封告警风暴
#   · **发信成功才落状态**：发送失败必须下一轮重试，绝不能"记成已通知"导致故障永不重报
#   · flock 单实例锁：一轮超过 cron 间隔时，重叠的那轮安静跳过
#   · 判活看心跳文件（每轮都写），不要看日志 mtime（只在有事件时才追加）
#
# 依赖：bash、docker、flock、python3（仅发信与存储段需要）
# 调用：用户级 crontab  `*/2 * * * * /path/to/container-watchdog.sh`（不需要 root）
# =============================================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# =============================== 配置区 ======================================
# 部署目录：日志 / 心跳 / 锁 / 状态文件都放这里（也是下面默认路径的基准）
# 默认 = 本脚本所在目录（三件套放在同一目录即可直接用）；要落到别处请设 WATCHDOG_BASE_DIR。
BASE_DIR="${WATCHDOG_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# 邮件正文里显示的这台机器的地址（内网 IP 或域名）。留空则只显示主机名。
HOST_LABEL="${WATCHDOG_HOST_LABEL:-}"

# 邮件正文里附加的排查入口（可留空），例如你的 Web 面板地址
PANEL_HINT="${WATCHDOG_PANEL_HINT:-}"

# 需要保活的容器，格式「容器名:compose 文件所在目录」，一行一个。
#   · 容器「存在但停了」-> docker start；容器「完全不存在」-> 进目录 docker compose up -d
#   · 不想让某个服务被自动拉起，删掉对应行即可
#   · 下面只是示例，换成你自己的
WATCH_CONTAINERS=(
  "web:${BASE_DIR}/web"
  "dns-updater:${BASE_DIR}/dns-updater"
)
# 也可以用环境变量整体覆盖（逗号分隔，适合演练或外部管理）：
#   WATCH_CONTAINERS 未设置 -> 用上面的列表；设为空串 -> 一个都不保活
if [ "${WATCHDOG_CONTAINERS+set}" = "set" ]; then
  WATCH_CONTAINERS=()
  [ -n "$WATCHDOG_CONTAINERS" ] && IFS=',' read -r -a WATCH_CONTAINERS <<<"$WATCHDOG_CONTAINERS"
fi

# ---- 证书热加载（不需要就留空）----
CERT="${WATCHDOG_CERT:-}"                        # acme 签出的 fullchain.cer 绝对路径
CERT_TARGETS="${WATCHDOG_CERT_TARGETS:-}"        # 续期后要重启的容器，空格分隔，如 "caddy nginx"
CADDY_CONTAINER="${WATCHDOG_CADDY_CONTAINER:-caddy}"   # 优先 reload 的 caddy 容器名，留空则直接重启

# ---- 邮件告警（发信脚本与凭据；凭据文件权限必须 600）----
MAILER="${BASE_DIR}/watchdog-mail.py"
MAIL_ENV="${BASE_DIR}/watchdog-mail.env"

# ---- 可选的「QQ 机器人掉线检测」段：填容器名才启用，留空即跳过 ----
NAPCAT_CONTAINER="${WATCHDOG_NAPCAT_CONTAINER:-}"

# ---- 可选的「ZFS 存储降级检测」段：需要同级目录有 zfs-health-probe.py 才能开 ----
STORAGE_ENABLED="${STORAGE_ENABLED:-no}"
STORAGE_PROBE="${WATCHDOG_STORAGE_PROBE:-${BASE_DIR}/zfs-health-probe.py}"

# ---- 容器网络自愈段 ----
NET_HEAL_ENABLED="${NET_HEAL_ENABLED:-yes}"

# ---- 演练开关（默认都不生效，行为与常规一致）----
#   MAIL_DRY=yes      只记日志不发信
#   NET_HEAL_DRY=yes  只记日志不挂网
#   STORAGE_PROBE_SRC=<假 status.json>  用假数据驱动存储段
#   NAPCAT_LOG_SRC=<假日志>             用假日志驱动掉线检测
MAIL_DRY="${MAIL_DRY:-no}"
NET_HEAL_DRY="${NET_HEAL_DRY:-no}"
STORAGE_PROBE_SRC="${STORAGE_PROBE_SRC:-}"
NAPCAT_LOG_SRC="${NAPCAT_LOG_SRC:-}"
# ============================= 配置区结束 ====================================

LOG="${BASE_DIR}/container-watchdog.log"
LOCK="${BASE_DIR}/container-watchdog.lock"
BEAT="${BASE_DIR}/container-watchdog.heartbeat"
CERT_STAMP="${BASE_DIR}/cert-renew.stamp"
NAPCAT_STATE="${BASE_DIR}/napcat-alert.state"
STORAGE_STATE="${BASE_DIR}/storage-alert.state"
NET_HEAL_STATE="${BASE_DIR}/network-alert.state"

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# 邮件正文里那一行「主机：…」
if [ -n "$HOST_LABEL" ]; then
  HOST_DESC="$(hostname) （$HOST_LABEL）"
else
  HOST_DESC="$(hostname)"
fi

# ---- 单实例锁：cron 每 2 分钟一轮，一轮超时会重叠 -> 同一故障被重复告警 ----
if command -v flock >/dev/null 2>&1; then
  if exec 9>"$LOCK" 2>/dev/null; then
    if ! flock -n 9; then
      log "上一轮仍在运行，跳过本轮（未取得锁）"
      exit 0
    fi
  else
    log "[warn] 锁文件 $LOCK 打不开，本轮不加锁继续"
  fi
fi

# ---- 心跳：每轮都写，用来判断"看门狗还活着"（别用日志 mtime 判活）----
{
  echo "last_run=$(date '+%F %T')"
  echo "pid=$$"
} >"$BEAT"

# ============================ 1) 容器保活 ====================================
check() {
  local name="$1" dir="$2" state
  state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
  if [ "$state" != "running" ]; then
    log "[$name] state=$state -> 拉起"
    if [ "$state" = "missing" ]; then
      (cd "$dir" && docker compose up -d >>"$LOG" 2>&1)
    else
      docker start "$name" >>"$LOG" 2>&1
    fi
    log "[$name] now=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)"
  fi
}

for entry in "${WATCH_CONTAINERS[@]}"; do
  [ -n "$entry" ] || continue
  check "${entry%%:*}" "${entry#*:}"
done

# ============================ 2) 证书热加载 ==================================
if [ -n "$CERT" ] && [ -f "$CERT" ]; then
  cur=$(stat -c '%Y-%s' "$CERT")
  old=$(cat "$CERT_STAMP" 2>/dev/null || true)
  if [ -n "$old" ] && [ "$old" != "$cur" ]; then
    log "证书已更新（$old -> $cur），开始逐个重启使用方"
    for svc in $CERT_TARGETS; do
      if [ -n "$CADDY_CONTAINER" ] && [ "$svc" = "$CADDY_CONTAINER" ]; then
        if docker exec "$svc" caddy reload --config /etc/caddy/Caddyfile >>"$LOG" 2>&1; then
          log "[$svc] 已 reload 新证书"
          continue
        fi
        log "[$svc] reload 失败，改为重启容器"
      fi
      docker restart "$svc" >>"$LOG" 2>&1
      log "[$svc] now=$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null)"
    done
  fi
  printf '%s\n' "$cur" >"$CERT_STAMP"
fi

# ---- 日志超过 500 行就裁剪 ----
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 500 ]; then
  tail -200 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# ============================ 3) 发信封装 ====================================
send_mail() {  # $1=主题 $2=正文
  if [ "$MAIL_DRY" = "yes" ]; then
    log "[mail] [dry-run] 跳过发送：「$1」"
    return 0
  fi
  if [ ! -f "$MAIL_ENV" ]; then
    log "[mail] 凭据文件缺失，跳过：「$1」"
    return 1
  fi
  printf '%s\n' "$2" | python3 "$MAILER" "$1" - >>"$LOG" 2>&1
  local rc=$?
  log "[mail] 「$1」退出码=$rc"
  return $rc
}

# ==================== 4) QQ 机器人（NapCat）掉线检测 ========================
# 判据（只扫描「自上次检查以来」的新增日志，2 分钟一轮不会漏）：
#   离线 = 新增日志里最后一条状态事件是「账号状态变更为离线」或 KickedOffLine
#   在线 = 最后一条是「已启用数据库辅助支持能力」（登录完成才会出现）
# 去重：状态存 NAPCAT_STATE，同一状态只发一次信；恢复时补发「已上线」
napcat_check() {
  [ -n "$NAPCAT_CONTAINER" ] || return 0
  local st last alert newlogs off_ln on_ln newalert now
  local name="$NAPCAT_CONTAINER"

  st=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
  if [ "$st" != "running" ]; then
    log "[$name] 容器状态=$st（拉起由保活段负责，本轮不发信）"
    return 0
  fi

  last=""; alert=none
  if [ -f "$NAPCAT_STATE" ]; then
    last=$(cut -d'|' -f1 "$NAPCAT_STATE")
    alert=$(cut -d'|' -f2 "$NAPCAT_STATE")
  fi

  if [ -n "$NAPCAT_LOG_SRC" ]; then
    newlogs=$(cat "$NAPCAT_LOG_SRC" 2>&1)
  elif [ -z "$last" ]; then
    now=$(date +%s)
    printf '%s|none\n' "$now" >"$NAPCAT_STATE"
    log "[$name] 首次运行：只记录基线时间戳，不告警"
    return 0
  else
    newlogs=$(docker logs --since "$(date -d "@$last" '+%Y-%m-%dT%H:%M:%S')" "$name" 2>&1)
  fi

  off_ln=$(printf '%s\n' "$newlogs" | grep -n -e '账号状态变更为离线' -e 'KickedOffLine' | tail -1 | cut -d: -f1)
  on_ln=$(printf '%s\n' "$newlogs" | grep -n -e '已启用数据库辅助支持能力' | tail -1 | cut -d: -f1)

  newalert="$alert"
  if [ -n "$off_ln" ] && { [ -z "$on_ln" ] || [ "$off_ln" -gt "$on_ln" ]; }; then
    if [ "$alert" != "offline" ]; then
      log "[$name] 判定离线（off行=$off_ln on行=$on_ln）-> 发告警"
      send_mail "[告警] QQ 机器人（NapCat）已掉线" "检测时间：$(date '+%F %T %Z')
主机：$HOST_DESC
结论：NapCat 账号状态为「离线」（多半是被风控踢下线）。

判据：自上次检查以来的日志里，最后一条状态事件是
  「账号状态变更为离线」或 KickedOffLine（第 $off_ln 行），其后没有登录成功事件。
${PANEL_HINT:+
处理建议：打开面板 $PANEL_HINT 检查登录状态，必要时重新扫码登录。}恢复上线后本脚本会再发一封恢复通知。"
      newalert=offline
    fi
  elif [ -n "$on_ln" ] && { [ -z "$off_ln" ] || [ "$on_ln" -gt "$off_ln" ]; }; then
    newalert=none
    if [ "$alert" = "offline" ]; then
      log "[$name] 已恢复在线 -> 发恢复通知"
      send_mail "[恢复] QQ 机器人（NapCat）已重新上线" "检测时间：$(date '+%F %T %Z')
主机：$HOST_DESC
结论：NapCat 已重新登录上线，告警解除。

判据：日志里出现「已启用数据库辅助支持能力」（第 $on_ln 行），
即登录完成后才有的标记。"
      newalert=none
    fi
  fi

  now=$(date +%s)
  printf '%s|%s\n' "$now" "$newalert" >"$NAPCAT_STATE"
}

napcat_check

# ==================== 5) ZFS 存储降级检测（可选）===========================
# 需要配套的 zfs-health-probe.py：读 `zpool status -j`，输出每行
#   <LEVEL>\t<SIGKEY>\t<消息>
# 判据覆盖：池/vdev（含 L2ARC cache、special、SLOG、热备）state 异常、READ/WRITE/CKSUM>0、
# 池 error_count>0、上次 scrub/resilver 报错、池从列表里消失、探针缺失。
# 为什么单独做：**L2ARC 掉线时池整体仍然是 ONLINE**，只看池 health 的巡检对它完全静默。
add_raw() {   # $1=LEVEL $2=SIGKEY $3=消息；raw 为空时不要留前导空行（会让签名漂）
  if [ -z "${raw:-}" ]; then
    raw=$(printf '%s\t%s\t%s' "$1" "$2" "$3")
  else
    raw=$(printf '%s\n%s\t%s\t%s' "$raw" "$1" "$2" "$3")
  fi
}

storage_check() {
  [ "$STORAGE_ENABLED" = "yes" ] || return 0
  local raw rc sig lvl last_sig last_lvl last_pools now list n note line
  local cur_pools p missing
  raw=""

  if [ ! -f "$STORAGE_PROBE" ]; then
    add_raw CRIT probe-missing "存储探针缺失：$STORAGE_PROBE（本轮存储检查未能进行，请检查部署）"
    rc=0
  elif [ -n "$STORAGE_PROBE_SRC" ]; then
    raw=$(python3 "$STORAGE_PROBE" "$STORAGE_PROBE_SRC" 2>>"$LOG"); rc=$?
  else
    raw=$(python3 "$STORAGE_PROBE" 2>>"$LOG"); rc=$?
  fi
  if [ "$rc" != "0" ] && [ -z "$raw" ]; then
    raw=$(printf 'CRIT\tprobe-failed\t无法读取 ZFS 状态（探针退出码 %s）' "$rc")
  fi

  # 当前池清单（与 state 里记的基线比对：池整体消失时 zpool 里什么都查不到）
  if [ -n "$STORAGE_PROBE_SRC" ]; then
    cur_pools=$(python3 "$STORAGE_PROBE" --pool-list "$STORAGE_PROBE_SRC" 2>>"$LOG" | sort | tr '\n' ',')
  else
    cur_pools=$(python3 "$STORAGE_PROBE" --pool-list 2>>"$LOG" | sort | tr '\n' ',')
  fi

  last_sig=""; last_lvl=""; last_pools=""; note=""; corrupt=no
  if [ ! -f "$STORAGE_STATE" ]; then
    note="状态文件缺失（按首次运行处理）"
  else
    line=$(head -1 "$STORAGE_STATE" 2>/dev/null || true)
    case "$line" in
      *'|'*)
        IFS='|' read -r last_sig last_lvl _ last_pools <<<"$line"
        case "$last_lvl" in
          ok|crit) ;;
          *) note="状态文件字段无效（lvl='$last_lvl'）"; corrupt=yes; last_sig=""; last_lvl="" ;;
        esac
        if [ "$corrupt" = "no" ] && [ "${#last_sig}" != "32" ]; then
          note="状态文件字段无效（签名长度 ${#last_sig}）"; corrupt=yes; last_sig=""; last_lvl=""
        fi
        ;;
      *) note="状态文件内容损坏（没有分隔符）"; corrupt=yes ;;
    esac
  fi

  # 期望池清单比对：基线里有、现在没有 -> 池整体消失（数据不一定丢，但必须立刻查）
  if [ "$corrupt" = "no" ] && [ -n "$last_pools" ]; then
    missing=""
    for p in $(printf '%s' "$last_pools" | tr ',' ' '); do
      [ -z "$p" ] && continue
      case ",$cur_pools," in
        *",$p,"*) ;;
        *) missing="$missing $p" ;;
      esac
    done
    for p in $missing; do
      add_raw CRIT "missing-pool:$p" "池 $p 从 zpool 列表中消失了（被 export/destroy、未导入，或盘全部掉线）—— 数据不一定丢，但请立刻用 zpool import 检查"
    done
  fi

  lvl=ok
  [ -n "$raw" ] && lvl=crit
  # 签名只看第 2 列 SIGKEY：盘错误计数从 12 涨到 99、scan 在跑，签名都不变 -> 不重发
  sig=$(printf '%s\n' "$raw" | cut -f2 | sort | md5sum | cut -d' ' -f1)
  now=$(date +%s)

  if [ "$lvl" = "ok" ]; then
    if [ "$corrupt" = "yes" ]; then
      log "[storage] $note；当前无异常，基线已重建 -> 发提示信"
      if send_mail "[提示] 存储状态文件异常（无法确认上次告警状态）" "检测时间：$(date '+%F %T %Z')
主机：$HOST_DESC
结论：$note
当前 ZFS 池 / 设备 / L2ARC **全部正常**，基线已重建为 ok。

为什么专门告诉你：状态文件异常时无法确认"上次是否发过存储告警"，
因此不排除你收到过一条告警却没收到对应的恢复信。若此前收到过
「[告警] ZFS 存储异常」，本条即视为**已解除**。"; then
        printf '%s|ok|%s|%s\n' "$sig" "$now" "$cur_pools" >"$STORAGE_STATE"
      else
        log "[storage] 提示信发送失败，保留旧状态，下一轮重试"
      fi
    elif [ "$last_lvl" = "crit" ]; then
      log "[storage] 已恢复正常 -> 发恢复通知"
      if send_mail "[恢复] ZFS 存储已恢复正常" "检测时间：$(date '+%F %T %Z')
主机：$HOST_DESC
结论：ZFS 池 / 数据设备 / L2ARC 已全部回到正常状态，之前的存储告警解除。"; then
        printf '%s|ok|%s|%s\n' "$sig" "$now" "$cur_pools" >"$STORAGE_STATE"
      else
        log "[storage] 恢复信发送失败，保留旧状态，下一轮重试"
      fi
    else
      # 首次运行（state 还不存在）：只记基线、不发信，避免部署时白打扰一次
      [ -n "$note" ] && log "[storage] $note；当前无异常，基线已记录（首次运行不发信）"
      printf '%s|ok|%s|%s\n' "$sig" "$now" "$cur_pools" >"$STORAGE_STATE"
    fi
    return 0
  fi

  [ -n "$note" ] && log "[storage] $note"

  if [ "$sig" = "$last_sig" ]; then
    return 0     # 同一故障状态（签名键相同），不重复打扰
  fi

  list=$(printf '%s\n' "$raw" | sed -e 's/^CRIT\t[^\t]*\t/- [严重] /' -e 's/^CRIT\t/- [严重] /' -e 's/^WARN\t[^\t]*\t/- [警告] /' -e 's/^WARN\t/- [警告] /')
  n=$(printf '%s\n' "$raw" | grep -c .)
  log "[storage] 发现存储异常 $n 项 -> 发告警"
  if send_mail "[告警] ZFS 存储异常（池 / 设备 / L2ARC／special）" "检测时间：$(date '+%F %T %Z')
主机：$HOST_DESC
结论：ZFS 检测到下列异常 ——
$list

判据：zpool status -j（ZFS 原生 JSON）里的池 state、各 vdev（含 L2ARC cache 段 / special 元数据
vdev / SLOG / 热备盘，这些都不在 vdevs 树里）的 state 与 READ/WRITE/CKSUM 计数、池 error_count、
最近 scrub·resilver 的错误数、ZFS 诊断消息（msgid），以及期望池清单（少池即报）。

处理建议：
 1) 看详情：ssh <用户名>@<NAS 地址>  然后  sudo -n /sbin/zpool status -v
 2) 数据盘 DEGRADED/FAULTED：别急着重启服务，先看 zpool status -v 是否列出损坏文件；
    有热备(spare)时 ZFS 一般会自动 resilver，等它跑完再看。
 3) L2ARC 掉线而池仍 ONLINE：属缓存降级，数据安全、只是变慢；确认盘/线后可用
    'zpool remove <池> <cache设备>' 摘掉，或换盘重加。
 4) 池从列表里消失：zpool import（不带参数）先看能不能扫到；别急着重启 NAS。

恢复正常后本脚本会再发一封恢复通知。"; then
    printf '%s|crit|%s|%s\n' "$sig" "$now" "$cur_pools" >"$STORAGE_STATE"
  else
    log "[storage] 告警发送失败（state 未更新），下一轮会重试"
  fi
}

storage_check

# ======================== 6) 容器网络自愈（v8）==============================
# 背景：NAS 冷启动时若宿主网络还没就绪（路由器/光猫尚未起来、DHCP 还没拿到地址），
#   dockerd 会给容器登记网络端点却没有真正建出 veth -> 容器 netns 里只剩 lo，
#   任何出网都是「Network is unreachable」。dockerd 不会自愈：docker restart 复用的
#   是那条坏记录（实测无效），只有新增端点的 docker network connect 才会真正重建网卡。
#   叠加 live-restore=true（容器进程一直 running），就成了静默失联。
# 判据：running 且 NetworkMode 不是 host/none/container:* 的容器，其
#   NetworkSettings.Networks 为空 -> 判定掉网 -> 挂回它自己的那个网络。
# 原则：只挂网、不重启容器（重启对这种情况无效，还会打断服务）。
net_heal() {
  [ "$NET_HEAL_ENABLED" = "yes" ] || return 0
  local name mode nets healed failed sig lvl last_sig
  healed=""
  failed=""

  for name in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name" 2>/dev/null) || continue
    case "$mode" in
      host|none|container:*|"") continue ;;
    esac
    nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$name" 2>/dev/null)
    [ -n "$nets" ] && continue
    if [ "$NET_HEAL_DRY" = "yes" ]; then
      log "[net] [dry-run] $name 无网络（应为 $mode），本轮不处理"
      continue
    fi
    if docker network connect "$mode" "$name" >>"$LOG" 2>&1; then
      log "[net] $name 掉网 -> 已挂回 $mode"
      healed="$healed$name($mode) "
    else
      log "[net] $name 掉网 -> 挂回 $mode 失败"
      failed="$failed$name($mode) "
    fi
  done

  # 状态签名：同一故障集合只发一次信，集合变了再发（同存储段做法）
  sig=""; lvl=ok
  if [ -n "$failed" ]; then
    lvl=failed; sig=$(printf 'failed:%s' "$failed" | md5sum | cut -d' ' -f1)
  elif [ -n "$healed" ]; then
    lvl=healed; sig=$(printf 'healed:%s' "$healed" | md5sum | cut -d' ' -f1)
  fi

  if [ "$lvl" = "ok" ]; then
    # 本轮无异常：基线清成 ok，这样「修好之后再次掉网」还能再报一次
    printf 'ok|none|%s\n' "$(date +%s)" >"$NET_HEAL_STATE" 2>/dev/null
    return 0
  fi

  last_sig=$(cut -d'|' -f1 "$NET_HEAL_STATE" 2>/dev/null || true)
  [ "$sig" = "$last_sig" ] && return 0

  if [ "$lvl" = "failed" ]; then
    log "[net] 有容器挂网失败 -> 发告警"
    if send_mail "[告警] 容器网络掉线，自动挂回失败" "检测时间：$(date '+%F %T %Z')
主机：$HOST_DESC
结论：下列容器处于「无网络」状态，脚本已尝试挂回但失败 ——
$(printf '%s\n' $failed | sed 's/^/- /')

判据：docker inspect 显示这些 running 容器的 NetworkSettings.Networks 为空
（正常至少应有一个网络），而 NetworkMode 不是 host/none。

常见原因与处理：
 1) 宿主网络当时还没就绪（断电后路由器尚未起来）-> 等 NAS 网络正常后下一轮会自动重试，
    也可手动执行：docker network connect <网络名> <容器名>
 2) 目标网络已被删除 -> docker network ls 确认网络还在（本段不会重建网络）。
 3) Docker 守护进程本身异常 -> 可考虑 sudo systemctl restart docker
    （会重建全部容器网络端点，期间服务短暂中断）。

说明：本段只挂网、不重启容器（实测 docker restart 对这种情况无效）。
修复成功后会再发一封提示信。"; then
      printf '%s|failed|%s\n' "$sig" "$(date +%s)" >"$NET_HEAL_STATE"
    else
      log "[net] 告警发送失败，保留旧状态，下一轮重试"
    fi
  else
    log "[net] 已自动挂回 ${healed}-> 发提示信"
    if send_mail "[提示] 容器网络掉线，已自动挂回" "检测时间：$(date '+%F %T %Z')
主机：$HOST_DESC
结论：检测到下列容器丢失网络，脚本已自动挂回它们的原网络，服务应已恢复 ——
$(printf '%s\n' $healed | sed 's/^/- /')

背景：NAS 冷启动时若宿主网络尚未就绪，dockerd 可能给容器登记了网络端点
却没有真正建出网卡（容器内只剩 lo，表现为「Network is unreachable」）。
Docker 不会自愈、也不会有任何提示，所以由本段兜底。

建议顺带确认：
 1) 相关服务是否已重新连上它的上游依赖（看容器日志）。
 2) 若这类掉网反复出现，可考虑给 NAS 配静态 IPv4，让开机时序更确定。"; then
      printf '%s|healed|%s\n' "$sig" "$(date +%s)" >"$NET_HEAL_STATE"
    else
      log "[net] 提示信发送失败，保留旧状态，下一轮重试"
    fi
  fi
}

net_heal
