#!/bin/bash
# Usage:
#   ./network-collect.sh -h hosts.txt -c commands.txt [-u user] [-p pass] [-P port] [-j jobs] [-t timeout]
# hosts.txt:    one IP/hostname per line (lines starting with # are ignored)
# commands.txt: one command per line (lines starting with # are ignored)

set -u

USERNAME="admin"
PASSWD=""
PORT=22
HOSTS_FILE=""
CMDS_FILE=""
MAX_JOBS=10
TIMEOUT=30

usage() {
    cat <<USAGE
Usage: $0 -h <hosts_file> -c <commands_file> [options]
  -h FILE   hosts file (one host per line)
  -c FILE   commands file (one command per line)
  -u USER   ssh username (default: admin)
  -p PASS   ssh password (or set env SW_PASSWD)
  -P PORT   ssh port (default: 22)
  -j N      max concurrent jobs (default: 10)
  -t SEC    per-command expect timeout (default: 30)
USAGE
    exit 1
}

while getopts "h:c:u:p:P:j:t:" opt; do
    case "$opt" in
        h) HOSTS_FILE="$OPTARG" ;;
        c) CMDS_FILE="$OPTARG" ;;
        u) USERNAME="$OPTARG" ;;
        p) PASSWD="$OPTARG" ;;
        P) PORT="$OPTARG" ;;
        j) MAX_JOBS="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        *) usage ;;
    esac
done

[[ -z "$HOSTS_FILE" || -z "$CMDS_FILE" ]] && usage
[[ ! -r "$HOSTS_FILE" ]] && { echo "cannot read hosts file: $HOSTS_FILE" >&2; exit 2; }
[[ ! -r "$CMDS_FILE"  ]] && { echo "cannot read commands file: $CMDS_FILE" >&2; exit 2; }

# Allow password from env to avoid leaking via ps
[[ -z "$PASSWD" && -n "${SW_PASSWD:-}" ]] && PASSWD="$SW_PASSWD"
if [[ -z "$PASSWD" ]]; then
    read -r -s -p "Password for $USERNAME: " PASSWD
    echo
fi

command -v expect >/dev/null 2>&1 || { echo "expect is required (apt install expect)" >&2; exit 3; }

RUN_TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="logs/${RUN_TS}"
mkdir -p "$LOG_DIR"
echo "Logs -> $LOG_DIR"

run_one() {
    local host="$1"
    local hostname="${2:-}"
    local logname="$host"
    [[ -n "$hostname" ]] && logname="${host}_${hostname}"
    local logfile="${LOG_DIR}/${logname}.log"

    {
        echo "=== host: $host ==="
        [[ -n "$hostname" ]] && echo "=== hostname: $hostname ==="
        echo "=== time: $(date '+%F %T') ==="
        echo "=== user: $USERNAME ==="
    } > "$logfile"

    PASSWD="$PASSWD" USERNAME="$USERNAME" PORT="$PORT" \
    HOST="$host" CMDS_FILE="$CMDS_FILE" TIMEOUT="$TIMEOUT" \
    expect <<'EOF' >> "$logfile" 2>&1
log_user 1
set timeout $env(TIMEOUT)
set host     $env(HOST)
set user     $env(USERNAME)
set password $env(PASSWD)
set port     $env(PORT)
set cmdsfile $env(CMDS_FILE)

# Generic prompt: a run of non-space chars (hostname/path) ending in a
# prompt-terminating char (], #, >, $) that is the LAST non-whitespace in the
# buffer (only trailing spaces/CR/LF allowed after it).
# This is deliberately strict: the old pattern allowed arbitrary punctuation
# after the prompt char, so it matched a stray '>' inside the login banner
# (SONiC's ASCII-art MOTD, e.g. the "> <" line), firing before the CLI was
# actually ready and causing the first command (conf t) to be sent into a dead
# prompt and lost.
# NOTE: ']' must be the FIRST char in the class (Tcl/expect quirk: \] inside [...] is unreliable).
set PROMPT {[^[:space:]]*[]#>$][[:space:]]*\Z}

spawn ssh -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o PreferredAuthentications=password,keyboard-interactive \
          -o PubkeyAuthentication=no \
          -o NumberOfPasswordPrompts=1 \
          -o ConnectTimeout=15 \
          -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
          -p $port $user@$host

expect {
    -re "(?i)password:"      { send -- "$password\r" }
    -re "(?i)yes/no.*"       { send -- "yes\r"; exp_continue }
    -re "(?i)permission denied" { puts "\n!!! auth failed"; exit 2 }
    timeout                  { puts "\n!!! connect timeout"; exit 3 }
    eof                      { puts "\n!!! connection closed"; exit 4 }
}

# After password, wait until the CLI is actually ready before sending anything.
# Some platforms (e.g. SONiC/UXOS) print the banner/MOTD and only start the
# interactive CLI a moment later. Poke a CR and require the prompt to come back
# TWICE in a row (i.e. idle/stable) so we never send the first command into a
# prompt that isn't accepting input yet. Each iteration re-arms the timeout, so
# a slow-booting CLI is tolerated up to $TIMEOUT per poke rather than racing.
set stable 0
while {$stable < 2} {
    send -- "\r"
    expect {
        -re $PROMPT              { incr stable }
        -re "(?i)password:"      { puts "\n!!! auth failed"; exit 2 }
        timeout                  { puts "\n!!! login timeout"; exit 3 }
        eof                      { puts "\n!!! connection closed"; exit 4 }
    }
}

# Run user commands.
# NOTE: logging out is NOT handled here on purpose. Vendors differ
# (Cisco/Ruijie "exit", Huawei/H3C "quit", others "logout"), so just put the
# appropriate quit command as the last line(s) of commands.txt. The eof branch
# below handles the case where that command drops the connection.
set had_timeout 0
set fp [open $cmdsfile r]
while {[gets $fp line] >= 0} {
    set trimmed [string trim $line]
    if {$trimmed eq "" || [string index $trimmed 0] eq "#"} { continue }
    send -- "$trimmed\r"
    expect {
        -re $PROMPT             { }
        -re "(?i)----( |-)*more" { send -- " "; exp_continue }
        -re "---- More ----"    { send -- " "; exp_continue }
        eof                     { break }
        timeout                 { puts "\n!!! timeout running: $trimmed"; set had_timeout 1 }
    }
}
close $fp

# Close the SSH session cleanly. If a logout command in commands.txt already
# dropped the connection, the spawn is already gone and this is a no-op.
catch {close}
catch {wait}
exit [expr {$had_timeout ? 5 : 0}]
EOF

    local rc=$?
    echo "=== rc: $rc ===" >> "$logfile"
    if [[ $rc -eq 0 ]]; then
        echo "[OK]   $host"
    else
        echo "[FAIL] $host (rc=$rc, see $logfile)"
    fi
}

# Concurrency control
running=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r host hostname _ <<< "$line"
    [[ -z "$host" ]] && continue

    run_one "$host" "$hostname" &

    running=$((running + 1))
    if (( running >= MAX_JOBS )); then
        wait -n 2>/dev/null || wait
        running=$((running - 1))
    fi
done < "$HOSTS_FILE"

wait
echo "Done. Logs in: $LOG_DIR"
