#!/usr/bin/env bash
# ============================================================
#  config_monitor.sh — Real-time config file change detector
#  Tracks: WHAT changed, WHO changed it, WHEN it happened
#  Method: inotifywait (event) + auditd (user attribution)
#  Author: root / sysadmin
#  Usage : sudo ./config_monitor.sh
# ============================================================

# ──────────────────────────────────────────────────────────────
#  DEFAULT CONFIG
# ──────────────────────────────────────────────────────────────
TARGETS=("/etc" "/opt")                        
LOGDIR="/var/log/config_monitor"               
TELEGRAM_BOT_TOKEN=" "                          
TELEGRAM_CHAT_ID=" "                            
BACKUP_DIR="/var/backups/config_monitor"
SNAPSHOT_ON_CHANGE=true
AUDIT_RULE_INSTALLED=false


ALLOWED_EXT=("conf" "cfg" "ini" "env")

# Blacklist user sistem 
SKIP_USERS=("root" "systemd" "daemon" "nobody" "www-data" "syslog" "_apt" "systemd-resolve" "systemd-timesync")

# Blacklist path pattern (substring match)
SKIP_PATHS=(
    "/etc/mtab"
    "/etc/resolv.conf"
    "/etc/hosts.bak"
    "/etc/ld.so.cache"
    "/etc/environment.d"
    "/etc/NetworkManager/system-connections"
    "/opt/google"
    "/opt/microsoft"
)

# Colours
RED='\033[0;31m'; YLW='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

# ──────────────────────────────────────────────────────────────
#  HELPER 
# ──────────────────────────────────────────────────────────────
is_allowed_ext() {
    local filepath="$1"
    local ext="${filepath##*.}"
    for allowed in "${ALLOWED_EXT[@]}"; do
        [[ "$ext" == "$allowed" ]] && return 0
    done
    return 1
}

# ──────────────────────────────────────────────────────────────
#  HELPER 
# ──────────────────────────────────────────────────────────────
is_skipped_path() {
    local filepath="$1"
    for pattern in "${SKIP_PATHS[@]}"; do
        [[ "$filepath" == *"$pattern"* ]] && return 0
    done
    return 1
}

# ──────────────────────────────────────────────────────────────
#  HELPER 
# ──────────────────────────────────────────────────────────────
is_skipped_user() {
    local user="$1"
    # Bersihkan suffix seperti "(lsof)" atau "(who)"
    local clean_user="${user%% *}"
    for skip in "${SKIP_USERS[@]}"; do
        [[ "$clean_user" == "$skip" ]] && return 0
    done
    return 1
}

# ──────────────────────────────────────────────────────────────
#  PRE-FLIGHT CHECKS
# ──────────────────────────────────────────────────────────────
preflight() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR]${RST} Must run as root."; exit 1; }

    for cmd in inotifywait auditctl ausearch; do
        if ! command -v "$cmd" &>/dev/null; then
            case "$cmd" in
                inotifywait)      PKG="inotify-tools" ;;
                auditctl|ausearch) PKG="auditd" ;;
            esac
            echo -e "${YLW}[WARN]${RST} '$cmd' not found. Install: apt install $PKG / yum install $PKG"
            [[ "$cmd" == "inotifywait" ]] && exit 1
        fi
    done

    for target in "${TARGETS[@]}"; do
        [[ ! -e "$target" ]] && { echo -e "${RED}[ERROR]${RST} Target not found: $target"; exit 1; }
    done

    mkdir -p "$LOGDIR" "$BACKUP_DIR"
}

# ──────────────────────────────────────────────────────────────
#  INSTALL AUDITD RULES
# ──────────────────────────────────────────────────────────────
setup_audit_rules() {
    if command -v auditctl &>/dev/null; then
        local installed=0
        for target in "${TARGETS[@]}"; do
            
            if ! auditctl -l 2>/dev/null | grep -q "^-w ${target} "; then
                if auditctl -w "$target" -p wa -k config_monitor 2>/dev/null; then
                    ((installed++))
                else
                    echo -e "${YLW}[WARN]${RST} Failed to install auditd rule for: $target"
                fi
            else
                echo -e "${CYN}[INFO]${RST} auditd rule already exists for: $target"
                ((installed++))
            fi
        done
        if [[ $installed -gt 0 ]]; then
            AUDIT_RULE_INSTALLED=true
            echo -e "${GRN}[OK]${RST} auditd rules active for: ${TARGETS[*]}"
        else
            echo -e "${YLW}[WARN]${RST} No auditd rules installed — user detection may be inaccurate"
        fi
    else
        echo -e "${YLW}[WARN]${RST} auditctl not found — user detection may be inaccurate"
    fi
}

remove_audit_rules() {
    if $AUDIT_RULE_INSTALLED; then
        for target in "${TARGETS[@]}"; do
            auditctl -W "$target" -p wa -k config_monitor 2>/dev/null
        done
    fi
}

# ──────────────────────────────────────────────────────────────
#  GET USER WHO MODIFIED FILE
# ──────────────────────────────────────────────────────────────
get_modifier_user() {
    local filepath="$1"
    local user="unknown"
    local pid=""

    
    for proc_fd_dir in /proc/[0-9]*/fd; do
        local proc_dir="${proc_fd_dir%/fd}"
        if ls -la "$proc_fd_dir" 2>/dev/null | grep -qF "$filepath"; then
            local uid_raw
            uid_raw=$(awk '/^Uid:/{print $2}' "$proc_dir/status" 2>/dev/null)
            if [[ -n "$uid_raw" ]]; then
                user=$(getent passwd "$uid_raw" 2>/dev/null | cut -d: -f1)
                [[ -z "$user" ]] && user="uid:$uid_raw"
                pid="${proc_dir##*/proc/}"
                break
            fi
        fi
    done

    
    if [[ "$user" == "unknown" ]]; then
        local lsof_out
        lsof_out=$(lsof "$filepath" 2>/dev/null | awk 'NR>1{print $3"|"$2}' | head -1)
        if [[ -n "$lsof_out" ]]; then
            user="${lsof_out%%|*} (lsof)"
            pid="${lsof_out##*|}"
        fi
    fi

    
    if [[ "$user" == "unknown" ]]; then
        local recent_pid
        
        for proc_fd_dir in /proc/[0-9]*/fd; do
            local proc_dir="${proc_fd_dir%/fd}"
            local proc_pid="${proc_dir##*/proc/}"
            # Skip proses sistem
            local uid_raw
            uid_raw=$(awk '/^Uid:/{print $2}' "$proc_dir/status" 2>/dev/null)
            [[ -z "$uid_raw" || "$uid_raw" == "0" ]] && continue
            
            local file_dir
            file_dir=$(dirname "$filepath")
            if ls -la "$proc_fd_dir" 2>/dev/null | grep -qF "$file_dir"; then
                local candidate
                candidate=$(getent passwd "$uid_raw" 2>/dev/null | cut -d: -f1)
                if [[ -n "$candidate" ]]; then
                    user="$candidate (proc-dir)"
                    pid="$proc_pid"
                    break
                fi
            fi
        done
    fi

    
    if [[ "$user" == "unknown" ]]; then
        
        local who_users
        who_users=$(who | awk '$1 != "root" {print $1}' | sort -u)
        if [[ -n "$who_users" ]]; then
            
            local count
            count=$(echo "$who_users" | wc -l)
            if [[ "$count" -eq 1 ]]; then
                user="$who_users (who)"
            else
                
                local recent_user
                recent_user=$(who | awk '$1 != "root"' | sort -k3,4 -r | awk 'NR==1{print $1}')
                [[ -n "$recent_user" ]] && user="$recent_user (who-recent)"
            fi
        fi
    fi

    
    if [[ "$user" == "unknown" ]]; then
        local last_user
        last_user=$(last -n 5 2>/dev/null | awk 'NR>0 && $1 != "root" && $1 != "reboot" && $1 != "wtmp" {print $1; exit}')
        [[ -n "$last_user" ]] && user="$last_user (last)"
    fi

    
    if [[ "$user" == "unknown" ]]; then
        user="$(stat -c '%U' "$filepath" 2>/dev/null) (file-owner)"
    fi

    echo "$user|$pid"
}

# ──────────────────────────────────────────────────────────────
#  SAVE BACKUP SNAPSHOT
# ──────────────────────────────────────────────────────────────
snapshot_file() {
    local filepath="$1"
    local timestamp="$2"
    local user="$3"

    [[ ! -f "$filepath" ]] && return

    local safe_name
    safe_name="$(echo "$filepath" | tr '/' '_')__${timestamp}__${user//[^a-zA-Z0-9]/_}"
    cp -p "$filepath" "${BACKUP_DIR}/${safe_name}" 2>/dev/null \
        && echo -e "    ${CYN}[snapshot]${RST} saved → ${BACKUP_DIR}/${safe_name}"
}

# ──────────────────────────────────────────────────────────────
#  SEND TELEGRAM
# ──────────────────────────────────────────────────────────────
send_telegram() {
    local message="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return

    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="${message}" \
        &>/dev/null
}

# ──────────────────────────────────────────────────────────────
#  BUILD TELEGRAM MESSAGE
# ──────────────────────────────────────────────────────────────
build_telegram_message() {
    local event="$1"
    local filepath="$2"
    local source_dir="$3"
    local user="$4"
    local pid="$5"
    local checksum="$6"
    local timestamp="$7"

    # Emoji per event type
    local emoji="🔔"
    case "$event" in
        MODIFY)    emoji="✏️"  ;;
        CREATE)    emoji="🆕"  ;;
        DELETE)    emoji="🗑️" ;;
        MOVED_IN)  emoji="📥"  ;;
        MOVED_OUT) emoji="📤"  ;;
        ATTRIB)    emoji="🔧"  ;;
    esac

    
    local diff_text=""
    local prev_snapshot
    prev_snapshot=$(ls -t "${BACKUP_DIR}/$(echo "$filepath" | tr "/" "_")"* 2>/dev/null | sed -n "2p")
    if [[ -n "$prev_snapshot" && -f "$filepath" ]]; then
        local raw_diff
        raw_diff=$(diff --unified=0 "$prev_snapshot" "$filepath" 2>/dev/null \
                   | grep -E "^\+[^+]|^-[^-]" | head -20)
        if [[ -n "$raw_diff" ]]; then
            diff_text="

📝 <b>Perubahan:</b>
<pre>${raw_diff}</pre>"
        fi
    fi

    printf '%s <b>CONFIG CHANGE DETECTED</b>\n\n🕐 <b>Waktu  :</b> %s\n📋 <b>Event  :</b> %s\n📁 <b>File   :</b> <code>%s</code>\n📂 <b>Source :</b> %s\n👤 <b>User   :</b> <b>%s</b>\n🔢 <b>PID    :</b> %s\n🔐 <b>SHA256 :</b> <code>%s...</code>%s' \
        "$emoji" "$timestamp" "$event" "$filepath" "$source_dir" \
        "$user" "${pid:-N/A}" "$checksum" "$diff_text"
}

# ──────────────────────────────────────────────────────────────
#  SEND ALERTS
# ──────────────────────────────────────────────────────────────
send_alert() {
    local subject="$1"
    local body="$2"
    local tg_message="$3"
    

    if [[ -n "$tg_message" ]]; then
        send_telegram "$tg_message"
    fi
}

# ──────────────────────────────────────────────────────────────
#  SHOW DIFF
# ──────────────────────────────────────────────────────────────
show_diff() {
    local filepath="$1"
    local prev_snapshot
    prev_snapshot=$(ls -t "${BACKUP_DIR}/$(echo "$filepath" | tr "/" "_")"* 2>/dev/null | sed -n "2p")
    [[ -z "$prev_snapshot" ]] && return

    local diff_output
    diff_output=$(diff --unified=2 "$prev_snapshot" "$filepath" 2>/dev/null)
    [[ -z "$diff_output" ]] && return

    echo "  │"
    echo "  │ ── CHANGES ──────────────────────────────────"
    while IFS= read -r line; do
        case "${line:0:1}" in
            +) echo -e "  │ \033[0;32m${line}\033[0m" ;;
            -) echo -e "  │ \033[0;31m${line}\033[0m" ;;
            @) echo -e "  │ \033[0;36m${line}\033[0m" ;;
            *) echo    "  │ ${line}" ;;
        esac
    done <<< "$diff_output"
    echo "  └─────────────────────────────────────────────"
}

# ──────────────────────────────────────────────────────────────
#  LOG EVENT
# ──────────────────────────────────────────────────────────────
log_event() {
    local event="$1"
    local filepath="$2"
    local source_dir="$3"     # /etc atau /opt
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    
    local safe_dir="${source_dir//\//_}"
    local logfile="${LOGDIR}/changes${safe_dir}.log"
    touch "$logfile"

    local user_info
    user_info=$(get_modifier_user "$filepath")
    local user="${user_info%%|*}"
    local pid="${user_info##*|}"

    
    if is_skipped_user "$user"; then
        return
    fi

    local checksum="N/A"
    [[ -f "$filepath" ]] && checksum=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 | head -c 16)

    # ── Terminal output ──
    echo -e ""
    echo -e "  ${BLD}${YLW}⚠  CONFIG CHANGE DETECTED${RST}"
    echo -e "  ┌─────────────────────────────────────────────"
    echo -e "  │ ${BLD}Time   :${RST} $timestamp"
    echo -e "  │ ${BLD}Event  :${RST} ${RED}$event${RST}"
    echo -e "  │ ${BLD}File   :${RST} $filepath"
    echo -e "  │ ${BLD}Source :${RST} $source_dir"
    echo -e "  │ ${BLD}User   :${RST} ${GRN}$user${RST}"
    [[ -n "$pid" ]] && \
    echo -e "  │ ${BLD}PID    :${RST} $pid"
    echo -e "  │ ${BLD}SHA256 :${RST} ${checksum}..."
    echo -e "  └─────────────────────────────────────────────"

    # ── Log file ──
    printf '[%s] event=%s file="%s" source=%s user=%s pid=%s sha256=%s\n' \
        "$timestamp" "$event" "$filepath" "$source_dir" "$user" "${pid:-N/A}" "$checksum" \
        >> "$logfile"

    
    $SNAPSHOT_ON_CHANGE && [[ "$event" != "DELETE" ]] && \
        snapshot_file "$filepath" "$(date '+%Y%m%d_%H%M%S')" "$user"

    # ── Diff terminal ──
    show_diff "$filepath"

    
    local tg_message
    tg_message=$(build_telegram_message \
        "$event" "$filepath" "$source_dir" \
        "$user" "$pid" "$checksum" "$timestamp")

    # ── Alert ──
    send_alert \
        "[config_monitor] $event on $filepath by $user" \
        "Time: $timestamp\nEvent: $event\nFile: $filepath\nSource: $source_dir\nUser: $user\nPID: ${pid:-N/A}\nSHA256: ${checksum}..." \
        "$tg_message"
}

# ──────────────────────────────────────────────────────────────
#  MONITOR TARGET
# ──────────────────────────────────────────────────────────────
monitor_target() {
    local target="$1"

    inotifywait -m -r \
        -e modify,create,delete,moved_to,moved_from,attrib \
        --format '%e|%w%f' \
        "$target" \
    2>/dev/null \
    | while IFS='|' read -r events filepath; do

        # Filter 1: ekstensi
        is_allowed_ext "$filepath" || continue

        # Filter 2: path blacklist
        is_skipped_path "$filepath" && continue

        # Map event label
        case "$events" in
            *MODIFY*)     label="MODIFY"   ;;
            *CREATE*)     label="CREATE"   ;;
            *DELETE*)     label="DELETE"   ;;
            *MOVED_TO*)   label="MOVED_IN" ;;
            *MOVED_FROM*) label="MOVED_OUT";;
            *ATTRIB*)     label="ATTRIB"   ;;
            *)            label="$events"  ;;
        esac

        log_event "$label" "$filepath" "$target"
    done
}

# ──────────────────────────────────────────────────────────────
#  GRACEFUL SHUTDOWN
# ──────────────────────────────────────────────────────────────
cleanup() {
    
    trap - SIGINT SIGTERM

    echo -e "\n${YLW}[INFO]${RST} Stopping all monitors — removing audit rules..."
    remove_audit_rules

    
    local child_pids
    child_pids=$(jobs -p 2>/dev/null)
    if [[ -n "$child_pids" ]]; then
        kill $child_pids 2>/dev/null
        wait $child_pids 2>/dev/null
    fi

    echo -e "${GRN}[DONE]${RST} Exited cleanly."
    exit 0
}
trap cleanup SIGINT SIGTERM

# ──────────────────────────────────────────────────────────────
#  MAIN
# ──────────────────────────────────────────────────────────────
main() {
    preflight
    setup_audit_rules

    echo -e ""
    echo -e "${BLD}${GRN}  ██████╗ ██████╗ ███╗  ██╗███████╗██╗ ██████╗${RST}"
    echo -e "${BLD}${GRN} ██╔════╝██╔═══██╗████╗ ██║██╔════╝██║██╔════╝${RST}"
    echo -e "${BLD}${GRN} ██║     ██║   ██║██╔██╗██║█████╗  ██║██║  ███╗${RST}"
    echo -e "${BLD}${GRN} ██║     ██║   ██║██║╚████║██╔══╝  ██║██║   ██║${RST}"
    echo -e "${BLD}${GRN} ╚██████╗╚██████╔╝██║ ╚███║██║     ██║╚██████╔╝${RST}"
    echo -e "${BLD}${GRN}  ╚═════╝ ╚═════╝ ╚═╝  ╚══╝╚═╝     ╚═╝ ╚═════╝${RST}"
    echo -e "  ${BLD}Config Change Monitor${RST} — running as PID $$"
    echo -e ""
    echo -e "  ${CYN}Targets :${RST} ${TARGETS[*]}"
    echo -e "  ${CYN}Filter  :${RST} ${ALLOWED_EXT[*]}"
    echo -e "  ${CYN}Log Dir :${RST} $LOGDIR"
    echo -e "  ${CYN}Backup  :${RST} $BACKUP_DIR"
    echo -e "  ${CYN}Auditd  :${RST} $($AUDIT_RULE_INSTALLED && echo 'active' || echo 'not available')"
    echo -e ""
    echo -e "  Watching for changes... (Ctrl+C to stop)"
    echo -e "  ─────────────────────────────────────────────"

    
    for target in "${TARGETS[@]}"; do
        echo -e "  ${GRN}[WATCH]${RST} Monitoring: $target"
        monitor_target "$target" &
    done

    
    wait
}

main "$@"