#!/bin/bash
# ==============================================================================
# uxos_pusher.sh — 浪潮 UXOS (SONiC) 交换机配置批量推送
#
# 与通用版 network-cli_pusher.sh 的区别（全部来自 UXOS 手工刷机日志的实测教训）：
#
#   1) 逐行发送 + 等提示符。手工整段粘贴会出现输入抢跑，日志里能看到
#      "interface ethC-Leaf02(config)#" 这类回显错位，命令可能被吞。
#   2) 客户端过滤注释。UXOS 不认 '#' 注释，手工刷时 "# trunk端口配置" 之类
#      全部回了 "Invalid command"。FRR 的 '!' 同理。
#   3) 交互式输入由"提示符驱动"，不按行号硬编码：
#        - "[sudo] password for admin:"  → 永远用登录密码回答（sudo 有凭证
#          缓存，第二条 snmp-agent 命令就不再弹了，硬编码必错位）
#        - "SNMP community:"             → 用配置文件里跟在该命令后的答案行
#      因此配置文件里等于登录密码的那一行会被识别为 sudo 答案并丢弃。
#   4) 提示符正则收紧为 UXOS 的 '#'，且要求在缓冲区末尾。banner 里有
#      "#1 SMP Debian" 和 ASCII art 的 "> <"，宽松正则会误判成提示符。
#   5) 慢命令单独给长超时（write force / ar enable / 范围口 switchport 等，
#      实测单条要 10~30s+）。
#
# 用法:
#   ./uxos_pusher.sh --dry-run                    # 只看计划，不连设备
#   ./uxos_pusher.sh -p 'zx1qaz@WSX'              # 正式推送
#   ./uxos_pusher.sh -p 'PASS' --only C-Leaf01    # 只推一台
#
# 注意: 配置末尾的 #reboot 是注释掉的，本脚本不会重启设备。
#       "ar enable" 需要保存配置 + 重启才生效，请自行安排重启窗口。
# ==============================================================================

set -u

# ---------- 默认值 ----------
USERNAME="admin"
PASSWD=""
SUDO_PASSWD=""
PORT=22
HOSTS_FILE="/Users/hollis/Documents/Switch_Configer/hosts.txt"
CONFIG_ROOT="/Users/hollis/Library/CloudStorage/OneDrive-Personal/Infrawaves/Case/2026-09-02-顺义东方国信32台X300集群/顺义东方国信32台X300集群"
CONFIG_FILE=""          # 显式指定单个配置文件（覆盖按主机名查找）
MAX_JOBS=6
TIMEOUT=90              # 普通命令超时
SLOW_TIMEOUT=600        # 慢命令超时
LOGOUT_CMD="logout"
DRY_RUN=0
ASSUME_YES=0
STRICT=0
VERBOSE=0
ONLY=""
SPAWN_CMD=""            # 测试用: 用本地命令代替 ssh

usage() {
    cat <<'USAGE'
用法: uxos_pusher.sh [选项]

  -u USER          ssh 用户名 (默认: admin)
  -p PASS          登录密码 (也可用环境变量 SW_PASSWD；不给则交互式询问)
  --sudo-pass PASS sudo 密码 (默认同登录密码)
  -P PORT          ssh 端口 (默认: 22)
  -h FILE          设备列表 "IP 主机名" (默认: Switch_Configer/hosts.txt)
  -C DIR           配置文件根目录，按 <主机名>.txt 递归查找
  -f FILE          显式指定配置文件（单机场景，覆盖 -C 查找）
  -j N             并发数 (默认: 6)
  -t SEC           普通命令超时 (默认: 90)
  --slow-timeout N 慢命令超时 (默认: 600)
  --only LIST      只处理这些主机，逗号分隔，可写主机名或 IP
  --logout CMD     退出命令 (默认: logout；UXOS 基础提示符不认 exit)
  --strict         某台设备一旦报错立即停止该设备后续命令
  --dry-run        只打印将要发送的命令，不连接设备
  -y, --yes        跳过确认
  -v, --verbose    dry-run 时打印完整命令队列
  --spawn-cmd CMD  用本地命令代替 ssh（自测用）
  --help           显示本帮助
USAGE
    exit 1
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) USERNAME="$2"; shift 2 ;;
        -p) PASSWD="$2"; shift 2 ;;
        --sudo-pass) SUDO_PASSWD="$2"; shift 2 ;;
        -P) PORT="$2"; shift 2 ;;
        -h) HOSTS_FILE="$2"; shift 2 ;;
        -C) CONFIG_ROOT="$2"; shift 2 ;;
        -f) CONFIG_FILE="$2"; shift 2 ;;
        -j) MAX_JOBS="$2"; shift 2 ;;
        -t) TIMEOUT="$2"; shift 2 ;;
        --slow-timeout) SLOW_TIMEOUT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --logout) LOGOUT_CMD="$2"; shift 2 ;;
        --strict) STRICT=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        --spawn-cmd) SPAWN_CMD="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

[[ -r "$HOSTS_FILE" ]] || { echo "读不到设备列表: $HOSTS_FILE" >&2; exit 2; }
command -v expect >/dev/null 2>&1 || { echo "需要 expect (brew install expect)" >&2; exit 3; }

# 密码: 命令行 > 环境变量 > 交互询问
[[ -z "$PASSWD" && -n "${SW_PASSWD:-}" ]] && PASSWD="$SW_PASSWD"
if [[ -z "$PASSWD" && $DRY_RUN -eq 0 ]]; then
    read -r -s -p "密码 ($USERNAME): " PASSWD; echo
fi
[[ -z "$SUDO_PASSWD" ]] && SUDO_PASSWD="$PASSWD"

RUN_TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/Users/hollis/Documents/Switch_Configer/logs/uxos-${RUN_TS}"
STATUS_DIR="${LOG_DIR}/.status"
QUEUE_DIR="${LOG_DIR}/.queue"
mkdir -p "$STATUS_DIR" "$QUEUE_DIR"

BOM="$(printf '\357\273\277')"

# ---------- 配置文件 → 命令队列 ----------
# 输出 TSV: "C<TAB>命令" 或 "A<TAB>交互式答案"
# 统计信息走 stderr，不污染队列。
preprocess() {
    local src="$1" dst="$2"
    # 注意: 环境变量必须挂在 awk 上（管道里前缀赋值只作用于第一个命令）
    sed "1s/^${BOM}//" "$src" \
    | LOGIN_PASS="$PASSWD" SUDO_PASS="$SUDO_PASSWD" awk '
    BEGIN { pend=0; ncmd=0; nans=0; ndrop=0 }
    {
        line=$0
        sub(/\r$/,"",line)
        gsub(/^[ \t]+/,"",line); gsub(/[ \t]+$/,"",line)
        if (line=="") next

        # 显式标注的答案行（给以后的配置文件用）
        if (line ~ /^#@answer[ \t]+/) { a=line; sub(/^#@answer[ \t]+/,"",a); print "A\t" a; nans++; next }

        # 注释: UXOS 不认 #，FRR 用 !
        if (line ~ /^[#!]/) next

        # 上一条命令是交互式命令 → 后面若干行可能是答案
        if (pend>0) {
            if (line==ENVIRON["LOGIN_PASS"] || line==ENVIRON["SUDO_PASS"]) {
                # sudo 答案: 丢掉，改由脚本按提示符实时回答
                pend--; ndrop++; next
            }
            if (line ~ /^(exit|end|quit|conf t|configure terminal|vtysh|write force|write)$/ || line ~ /[ \t]/) {
                pend=0     # 明显是命令，答案区结束
            } else {
                print "A\t" line; nans++; pend--; next
            }
        }

        print "C\t" line; ncmd++
        if (line ~ /^(no[ \t]+)?snmp-agent[ \t]+community/) pend=2
    }
    END { printf("cmds=%d answers=%d dropped_sudo=%d\n", ncmd, nans, ndrop) > "/dev/stderr" }
    ' > "$dst" 2>"${dst}.stats"
    cat "${dst}.stats"
}

# 按主机名递归查找配置文件
find_config() {
    local hostname="$1"
    [[ -n "$CONFIG_FILE" ]] && { echo "$CONFIG_FILE"; return; }
    find "$CONFIG_ROOT" -type f -name "${hostname}.txt" 2>/dev/null | head -1
}

# 日志脱敏（设备不回显 sudo 密码，这里是兜底）
mask_log() {
    local f="$1"; shift
    local secret esc tmp="${f}.mask"
    [[ -f "$f" ]] || return 0
    cp "$f" "$tmp" 2>/dev/null || return 0
    for secret in "$@"; do
        [[ -z "$secret" ]] && continue
        esc=$(printf '%s' "$secret" | sed 's/[][\.*^$\/&]/\\&/g')
        sed "s/${esc}/********/g" "$tmp" > "${tmp}.2" 2>/dev/null && mv "${tmp}.2" "$tmp"
    done
    mv "$tmp" "$f"
}

# ---------- 单台设备 ----------
run_one() {
    local host="$1" hostname="$2" cfg="$3"
    local logfile="${LOG_DIR}/${hostname}_${host}.log"
    local queue="${QUEUE_DIR}/${hostname}.queue"
    local stats ncmd rc

    stats="$(preprocess "$cfg" "$queue")"
    ncmd=$(awk -F'\t' '$1=="C"' "$queue" | wc -l | tr -d ' ')

    {
        echo "=== host     : $host"
        echo "=== hostname : $hostname"
        echo "=== config   : $cfg"
        echo "=== queue    : $stats"
        echo "=== time     : $(date '+%F %T')"
        echo "=== user     : $USERNAME"
        echo "=== ---------------------------------------------"
    } > "$logfile"

    TIMEOUT="$TIMEOUT" SLOW_TIMEOUT="$SLOW_TIMEOUT" \
    HOST="$host" USERNAME="$USERNAME" PASSWD="$PASSWD" SUDO_PASSWD="$SUDO_PASSWD" \
    PORT="$PORT" QUEUE="$queue" LOGOUT_CMD="$LOGOUT_CMD" STRICT="$STRICT" \
    SPAWN_CMD="$SPAWN_CMD" \
    expect <<'EXPECT_EOF' >> "$logfile" 2>&1
log_user 1
set base_timeout  $env(TIMEOUT)
set slow_timeout  $env(SLOW_TIMEOUT)
set host          $env(HOST)
set user          $env(USERNAME)
set password      $env(PASSWD)
set sudopass      $env(SUDO_PASSWD)
set port          $env(PORT)
set queuefile     $env(QUEUE)
set logoutcmd     $env(LOGOUT_CMD)
set strict        $env(STRICT)
set spawncmd      $env(SPAWN_CMD)

# UXOS 提示符: 行首主机名 + 可选 (模式) + '#'，且必须在缓冲区末尾。
# 必须严格: banner 有 "#1 SMP Debian"，ASCII art 有 "> <"。
# 尾部要容忍 BEL(\a): UXOS 拒绝非法命令时会 "擦除+重画提示符+响铃"，
# 提示符后跟一个 0x07。BEL 不是 POSIX space，早期版本会在这里失配并空等到超时。
set PROMPT {(?n)^[^[:space:]]+(\([^)]*\))?#[[:space:]\a]*\Z}
set SUDO   {(?in)\[sudo\] password for [^:]*:[[:space:]]*\Z}
set SNMPQ  {(?in)SNMP community:[[:space:]]*\Z}
set YESNO  {(?in)(\[Y/N\]|\(y/n\)|\[yes/no\])[^\n]*[:?][[:space:]]*\Z}
set MORE   {(?i)-+[[:space:]]*more[[:space:]]*-+}
set ERRRE  {(?i)(invalid command|unknown command|syntax error|incomplete command|command incomplete|%[[:space:]]*(invalid|unknown|error))}

# 需要长超时的命令（实测: write force / ar enable / 范围口操作都很慢）
set SLOWRE {(?i)(^write|ar enable|no container-feature|carrier-delay|switchport|routerport|^interface ethernet [0-9]+-[0-9]+|access-rule|^bind |reboot|snmp-agent)}

# 必须在 spawn 之前把 PTY 宽度设足。expect 默认给 0x0 的 PTY，两边的行编辑器
# 拿不到宽度就退回假定 ~72 列，然后往回显里塞折行控制符:
#   UXOS CLI  → 第 72 列插 ESC E (NEL)
#   FRR vtysh → 第 73 列插裸 CR，并重发落在末列的那个字符
# 命令本身是完整送达的，但日志会被折行搅乱、没法直接 diff 审计。
set stty_init "columns 512 rows 100"

if {$spawncmd ne ""} {
    eval spawn $spawncmd
} else {
    spawn ssh -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o PreferredAuthentications=password,keyboard-interactive \
              -o PubkeyAuthentication=no \
              -o NumberOfPasswordPrompts=2 \
              -o ConnectTimeout=15 \
              -o HostKeyAlgorithms=+ssh-rsa \
              -o PubkeyAcceptedAlgorithms=+ssh-rsa \
              -p $port $user@$host
}

# ---------- 登录 ----------
set timeout $base_timeout
set pwsent 0
set logged_in 0
expect {
    -re {(?i)assword:}          { incr pwsent
                                  if {$pwsent > 2} { puts "\n!!! 密码被反复索要，认证失败"; exit 2 }
                                  send -- "$password\r"; exp_continue }
    -re {(?i)(yes/no|fingerprint)} { send -- "yes\r"; exp_continue }
    -re {(?i)permission denied} { puts "\n!!! 认证失败"; exit 2 }
    -re $PROMPT                 { set logged_in 1 }
    timeout                     { puts "\n!!! 登录超时"; exit 3 }
    eof                         { puts "\n!!! 连接被关闭"; exit 4 }
}

# UXOS 会先打 Linux banner，再启动 UXOS CLI。要求提示符连续稳定两次，
# 否则第一条命令可能发进还没就绪的 CLI 里丢掉。
set stable 0
while {$stable < 2} {
    send -- "\r"
    expect {
        -re $PROMPT             { incr stable }
        -re {(?i)assword:}      { puts "\n!!! 认证失败"; exit 2 }
        timeout                 { puts "\n!!! 等待 CLI 就绪超时"; exit 3 }
        eof                     { puts "\n!!! 连接被关闭"; exit 4 }
    }
}

# ---------- 读队列 ----------
# 每条命令记录 = {命令 {答案列表}}
set cmds {}
set fp [open $queuefile r]
while {[gets $fp line] >= 0} {
    set tab "\t"
    set idx [string first $tab $line]
    if {$idx < 0} { continue }
    set kind [string range $line 0 [expr {$idx-1}]]
    set text [string range $line [expr {$idx+1}] end]
    if {$kind eq "C"} {
        lappend cmds [list $text {}]
    } elseif {$kind eq "A"} {
        if {[llength $cmds] == 0} { continue }
        set i [expr {[llength $cmds]-1}]
        set rec [lindex $cmds $i]
        set ans [lindex $rec 1]
        lappend ans $text
        lset cmds $i [list [lindex $rec 0] $ans]
    }
}
close $fp

# ---------- 逐行下发 ----------
set nsent 0
set nerr 0
set ntimeout 0
set eofhit 0

foreach rec $cmds {
    set cmd     [lindex $rec 0]
    set pending [lindex $rec 1]

    if {[regexp $SLOWRE $cmd]} { set timeout $slow_timeout } else { set timeout $base_timeout }

    send -- "$cmd\r"
    incr nsent
    set done 0
    while {!$done} {
        expect {
            -re $SUDO {
                send -- "$sudopass\r"
                puts "\n<<< 已应答 sudo 密码提示 >>>"
            }
            -re $SNMPQ {
                if {[llength $pending] > 0} {
                    set a [lindex $pending 0]
                    set pending [lrange $pending 1 end]
                    send -- "$a\r"
                    puts "\n<<< 已应答 SNMP community 提示 >>>"
                } else {
                    puts "\n!!! 没有可用答案应答 SNMP community 提示 (命令: $cmd)"
                    incr nerr
                    send -- "\r"
                }
            }
            -re $YESNO { send -- "y\r"; puts "\n<<< 自动确认 y >>>" }
            -re $MORE  { send -- " " }
            -re $ERRRE { incr nerr; puts "\n!!! 设备报错，命令: $cmd"; exp_continue }
            -re $PROMPT { set done 1 }
            timeout {
                puts "\n!!! 超时，命令: $cmd"
                incr ntimeout
                set done 1
            }
            eof {
                puts "\n!!! 连接中断，命令: $cmd"
                set eofhit 1
                set done 1
            }
        }
    }

    if {[llength $pending] > 0} {
        puts "\n!!! 警告: 命令 \"$cmd\" 有未被消费的答案行 $pending"
    }
    if {$eofhit} { break }
    if {$strict && $nerr > 0} { puts "\n!!! strict 模式: 检测到报错，停止后续命令"; break }
}

# ---------- 退出 ----------
# UXOS 基础提示符不认 "exit"（实测回 "Invalid command" + 擦除 + 响铃，会话不关），
# 所以默认用 "logout"。仍保留兜底: 被拒就退回 Ctrl-D(EOF)，最后才强关。
# 登出失败不算配置错误（write force 已经落盘），但要单独报出来，不能静默。
set logout_clean 0
set logout_note ""
if {!$eofhit} {
    set timeout 10
    send -- "$logoutcmd\r"
    expect {
        eof         { set logout_clean 1 }
        -re $ERRRE  { set logout_note "设备不接受登出命令 \"$logoutcmd\"，改用 Ctrl-D" }
        -re $PROMPT { set logout_note "登出命令 \"$logoutcmd\" 未关闭会话，改用 Ctrl-D" }
        timeout     { set logout_note "登出命令 \"$logoutcmd\" 无响应，改用 Ctrl-D" }
    }
    # 退回 Ctrl-D：SONiC/UXOS 底层是 Linux shell，EOF 一定能断开。
    # 这里只认 eof —— 上一个分支可能在缓冲区里留了个提示符没消费掉，
    # 若再匹配 PROMPT 会立刻命中那个陈旧提示符，误判成"Ctrl-D 没生效"。
    if {!$logout_clean} {
        set timeout 10
        send -- "\004"
        expect {
            eof     { set logout_clean 1 }
            timeout { set logout_note "$logout_note；Ctrl-D 无响应，强制断开" }
        }
    }
}
catch {close}
catch {wait}

if {$logout_note ne ""} { puts "\n<<< 登出: $logout_note >>>" }
puts "\n=== 汇总: 已发送 $nsent 条, 报错 $nerr, 超时 $ntimeout, 登出[expr {$logout_clean ? {正常} : {异常}}] ==="
if {$ntimeout > 0} { exit 5 }
if {$nerr > 0}     { exit 6 }
exit 0
EXPECT_EOF

    rc=$?
    echo "=== rc: $rc ===" >> "$logfile"
    mask_log "$logfile" "$PASSWD" "$SUDO_PASSWD"

    if [[ $rc -eq 0 ]]; then
        echo "ok $hostname $host $ncmd" > "${STATUS_DIR}/${hostname}"
        echo "[OK]   $hostname ($host) — $ncmd 条命令"
    else
        echo "fail $hostname $host $rc" > "${STATUS_DIR}/${hostname}"
        echo "[FAIL] $hostname ($host) rc=$rc — 见 $logfile"
    fi
}

# ---------- 读设备列表 ----------
HOST_IPS=(); HOST_NAMES=(); HOST_CFGS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r ip name _ <<< "$line"
    [[ -z "${ip:-}" ]] && continue
    [[ -z "${name:-}" ]] && { echo "警告: $ip 没有主机名，跳过（需要主机名来定位配置文件）" >&2; continue; }
    if [[ -n "$ONLY" ]]; then
        case ",$ONLY," in
            *",$name,"*|*",$ip,"*) ;;
            *) continue ;;
        esac
    fi
    cfg="$(find_config "$name")"
    HOST_IPS+=("$ip"); HOST_NAMES+=("$name"); HOST_CFGS+=("${cfg:-}")
done < "$HOSTS_FILE"

[[ ${#HOST_IPS[@]} -eq 0 ]] && { echo "没有匹配到任何设备" >&2; exit 2; }

# ---------- 计划 / dry-run ----------
echo "配置根目录: $CONFIG_ROOT"
echo "日志目录  : $LOG_DIR"
echo
printf "%-12s %-16s %s\n" "主机名" "IP" "配置文件"
missing=0
for i in "${!HOST_IPS[@]}"; do
    cfg="${HOST_CFGS[$i]}"
    if [[ -z "$cfg" || ! -r "$cfg" ]]; then
        printf "%-12s %-16s %s\n" "${HOST_NAMES[$i]}" "${HOST_IPS[$i]}" "!!! 找不到配置文件"
        missing=$((missing+1))
    else
        printf "%-12s %-16s %s\n" "${HOST_NAMES[$i]}" "${HOST_IPS[$i]}" "$cfg"
    fi
done
echo

if [[ $DRY_RUN -eq 1 ]]; then
    for i in "${!HOST_IPS[@]}"; do
        cfg="${HOST_CFGS[$i]}"; name="${HOST_NAMES[$i]}"
        [[ -z "$cfg" || ! -r "$cfg" ]] && continue
        q="${QUEUE_DIR}/${name}.queue"
        stats="$(preprocess "$cfg" "$q")"
        echo "--- $name: $stats"
        awk -F'\t' '$1=="A" {print "      交互式答案 → " $2}' "$q"
        if [[ $VERBOSE -eq 1 ]]; then
            awk -F'\t' '{ if ($1=="C") print "  " $2; else print "      >>> " $2 }' "$q"
        fi
    done
    echo
    echo "dry-run 结束，未连接任何设备。队列文件在 $QUEUE_DIR"
    exit 0
fi

if [[ $missing -gt 0 ]]; then
    echo "有 $missing 台设备找不到配置文件，它们会被跳过。" >&2
fi

# ---------- 确认 ----------
if [[ $ASSUME_YES -eq 0 ]]; then
    echo "即将向以上 ${#HOST_IPS[@]} 台设备写入配置（含 write force，持久化生效）。"
    read -r -p "确认继续? [y/N] " ans < /dev/tty
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "已取消"; exit 0 ;;
    esac
fi

# ---------- 并发执行 ----------
for i in "${!HOST_IPS[@]}"; do
    cfg="${HOST_CFGS[$i]}"; name="${HOST_NAMES[$i]}"; ip="${HOST_IPS[$i]}"
    if [[ -z "$cfg" || ! -r "$cfg" ]]; then
        echo "skip $name $ip nocfg" > "${STATUS_DIR}/${name}"
        echo "[SKIP] $name ($ip) — 找不到配置文件"
        continue
    fi
    while [[ $(jobs -pr | wc -l | tr -d ' ') -ge $MAX_JOBS ]]; do sleep 0.5; done
    run_one "$ip" "$name" "$cfg" &
done
wait

# ---------- 汇总 ----------
echo
echo "===== 汇总 ====="
ok=0; fail=0; skip=0
for f in "$STATUS_DIR"/*; do
    [[ -f "$f" ]] || continue
    read -r st rest < "$f"
    case "$st" in
        ok)   ok=$((ok+1)) ;;
        fail) fail=$((fail+1)); echo "  FAIL: $rest" ;;
        skip) skip=$((skip+1)); echo "  SKIP: $rest" ;;
    esac
done
echo "成功 $ok / 失败 $fail / 跳过 $skip"
echo "日志: $LOG_DIR"
echo
echo "提醒: 'ar enable' 需要保存配置并重启才生效；配置里的 #reboot 是注释，本脚本不重启设备。"
[[ $fail -gt 0 ]] && exit 1
exit 0
