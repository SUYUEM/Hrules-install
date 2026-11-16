#!/usr/bin/env bash
set -u
umask 077

app=/usr/local/lib/hrules-six/hrules-six.py
manager=/usr/local/sbin/hrules-six
state=/var/lib/hrules-six/state.json
landing_state=/var/lib/hrules-six/landing/state.json
core=hrules-six-mihomo.service
subscription=hrules-six-subscription.service
timer=hrules-six-traffic.timer
timer_file=/etc/systemd/system/$timer
shortcut_dir=/usr/local/bin
shortcut_record=/var/lib/hrules-six/menu-shortcut
incoming=
title_color=
accent=
dim=
plain=
if [[ -t 1 && ${TERM:-} != dumb && -z ${NO_COLOR:-} ]]; then
    title_color=$'\033[1;32m'
    accent=$'\033[1;36m'
    dim=$'\033[2m'
    plain=$'\033[0m'
fi

cleanup() {
    if [[ -n $incoming ]]; then
        rm -f -- "$incoming"
    fi
}
trap cleanup EXIT

usage() {
    printf '%s\n' '用法  sudo bash hrules-six.sh [install|landing|node-suffix|status|links|quota|traffic-interval|outbound|nodes|shortcut|update] [选项]'
    printf '%s\n' '无参数打开管理菜单。首次打开后默认用 m 快捷启动。'
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi

self=$(readlink -f -- "${BASH_SOURCE[0]}") || exit 1
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$self" "$@"
    fi
    printf '%s\n' '请用 root 账号运行。' >&2
    exit 1
fi

backend_ready() {
    if [[ ! -f $state || ! -f $app ]]; then
        printf '%s\n' '请先选择 1 安装。' >&2
        return 1
    fi
}

traffic_ready() {
    backend_ready || return 1
    local help
    if [[ -f $timer_file ]] && help=$(python3 "$app" --help 2>/dev/null) &&
        [[ $help == *',quota,'* && $help == *',traffic-interval,'* ]]; then
        return 0
    fi
    printf '\n%s\n' '当前 VPS 仍在使用旧版服务程序。' \
        '请返回菜单，选择 1. 安装 / 更新协议服务。' >&2
    printf '\n也可在 SSH 终端执行以下命令更新。\n  sudo bash %q install\n' "$self" >&2
    return 1
}

run_backend() {
    case $1 in
        quota|traffic-interval) traffic_ready || return 1 ;;
        outbound|nodes)
            backend_ready || return 1
            local help command=$1
            if ! help=$(python3 "$app" --help 2>/dev/null) || [[ $help != *",$command,"* ]]; then
                printf '%s\n' '当前 VPS 的服务程序需更新。请返回菜单选择 1. 安装 / 更新协议服务。' >&2
                return 1
            fi
            ;;
        *) backend_ready || return 1 ;;
    esac
    python3 "$app" "$@"
}

extract_backend() {
    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s\n' '正在安装 Python 3。'
        apt-get update && apt-get install -y python3 || return 1
    fi
    incoming=$(mktemp /tmp/hrules-six-backend.XXXXXXXX.py) || return 1
    if ! python3 - "$self" "$incoming" <<'PY'
import base64
import binascii
import gzip
import hashlib
from pathlib import Path
import sys
import zlib

if sys.version_info < (3, 9):
    sys.exit("需要 Python 3.9 或以上。")

source = Path(sys.argv[1]).read_bytes()
_, separator, payload = source.partition(b"\n__HRULES_BACKEND_V1__\n")
lines = payload.splitlines()
if not separator or len(lines) != 3 or lines[-1] != b"__HRULES_BACKEND_END__":
    sys.exit("安装程序格式不完整。请重新下载并上传 hrules-six.sh。")
digest, data, _ = lines
try:
    backend = gzip.decompress(base64.b64decode(data, validate=True))
except (binascii.Error, EOFError, OSError, zlib.error):
    sys.exit("安装程序数据损坏。请重新下载并上传 hrules-six.sh。")
if hashlib.sha256(backend).hexdigest().encode("ascii") != digest:
    sys.exit("安装程序校验失败。请重新下载完整的 hrules-six.sh。")
Path(sys.argv[2]).write_bytes(backend)
PY
    then
        cleanup
        incoming=
        return 1
    fi
}

create_command_directory() (
    umask 022
    mkdir -p -- "$1"
)

install_manager() {
    local pending
    if [[ -x $manager ]] && cmp -s -- "$self" "$manager"; then
        return 0
    fi
    create_command_directory "${manager%/*}" || return 1
    pending=$(mktemp "${manager}.XXXXXXXX") || return 1
    if ! install -m 0755 -- "$self" "$pending" || ! mv -fT -- "$pending" "$manager"; then
        rm -f -- "$pending"
        return 1
    fi
}

ensure_manager() {
    [[ -x $manager ]] || install_manager
}

run_installer() {
    local action=$1
    shift
    extract_backend || return 1
    local rc=0
    python3 "$incoming" "$action" "$@" || rc=$?
    cleanup
    incoming=
    if (( rc == 3 )) && [[ $action == install ]]; then
        return 0
    fi
    if (( rc == 0 )) && [[ $action == install || $action == node-suffix || ( $action == landing && -f $landing_state ) ]]; then
        install_manager || return 1
        printf '\n%s\n' '命令行输入 sudo hrules-six 可重新打开菜单。'
    fi
    return "$rc"
}

install_stack() {
    run_installer install "$@"
}

edit_node_suffix() {
    backend_ready || return 1
    local help
    if ! help=$(python3 "$app" --help 2>/dev/null) || [[ $help != *'--node-suffix'* ]]; then
        printf '当前 VPS 服务程序需要先升级一次。请运行 sudo bash %q install，再使用菜单 1 → 4。\n' "$self" >&2
        return 1
    fi
    run_installer node-suffix "$@"
}

draw_install_menu() {
    local divider='────────────────────────────────────────────'
    printf '\n%s%s%s\n' "$title_color" '安装 / 更新协议服务' "$plain"
    printf '%s%s%s\n' "$dim" "$divider" "$plain"
    menu_heading '安装方式'
    menu_item 1 '安装推荐协议'
    menu_note 'IPv4 / 双栈 9 项，IPv6 单栈 2 项'
    menu_item 2 '自选安装协议'
    menu_note '多选时用空格分隔序号'
    menu_item 3 '独立 Shadowsocks 落地'
    menu_note '仅生成供入口 VPS 使用的独立链接'

    menu_heading '节点设置'
    menu_item 4 '自定义节点名称后缀'
    menu_item 5 '协议节点管理'
    printf '\n'
    menu_item 0 '返回主菜单'
    printf '%s%s%s\n\n' "$dim" "$divider" "$plain"
}

guided_install() {
    local choice
    draw_install_menu
    while read -r -p '请选择 [0–5]  ' choice; do
        case $choice in
            1) install_stack --profile recommended; return $? ;;
            2) install_stack --profile custom; return $? ;;
            3) run_installer landing; return $? ;;
            4) edit_node_suffix; return $? ;;
            5) run_backend nodes || :; draw_install_menu ;;
            0|'') return 0 ;;
            *) printf '%s\n' '请输入 0–5。' ;;
        esac
    done
}

show_services() {
    backend_ready || return 1
    local service status label
    for service in "$core" "$subscription" "$timer"; do
        case $service in
            "$core") label='代理服务' ;;
            "$subscription") label='订阅服务' ;;
            "$timer") label='流量采样' ;;
        esac
        status=$(systemctl is-active "$service" 2>/dev/null) || :
        case $status in
            active) status='运行中' ;;
            inactive) status='已停止' ;;
            failed) status='故障' ;;
            activating) status='启动中' ;;
            deactivating) status='停止中' ;;
            *) status='未就绪' ;;
        esac
        printf '  %s  %s\n' "$label" "$status"
    done
    printf '\n'
    run_backend quota
}

ask_limit() {
    traffic_ready || return 1
    local limit
    read -r -p '输入新的共享上限（GiB，0 为不限额，留空返回） ' limit || return 1
    if [[ -n $limit ]]; then
        python3 "$app" quota --limit-gb "$limit"
    fi
}

ask_reset() {
    traffic_ready || return 1
    local answer
    read -r -p '输入 RESET 清零累计流量 ' answer || return 1
    if [[ $answer == RESET ]]; then
        python3 "$app" quota --reset
    fi
}

ask_interval() {
    local seconds
    run_backend traffic-interval || return 1
    read -r -p '采样间隔（5 / 15 / 30 / 60 秒，留空返回） ' seconds || return 1
    if [[ -n $seconds ]]; then
        run_backend traffic-interval --seconds "$seconds"
    fi
}

ask_hop() {
    backend_ready || return 1
    local answer ports interval
    local -a options
    read -r -p '启用 Hysteria2 端口跳跃？[y/n，留空返回] ' answer || return 1
    case ${answer,,} in
        y|yes)
            read -r -p '附加 UDP 范围 [24000-24015] ' ports || return 1
            read -r -p '跳跃间隔（秒，如 30 或 15-45，留空沿用） ' interval || return 1
            options=(--hysteria2-hop-ports "${ports:-24000-24015}")
            if [[ -n $interval ]]; then
                options+=(--hysteria2-hop-interval "$interval")
            fi
            install_stack "${options[@]}"
            ;;
        n|no) install_stack --hysteria2-hop-ports none ;;
        '') return 0 ;;
        *) printf '%s\n' '请输入 y 或 n。' >&2; return 1 ;;
    esac
}

ask_hysteria_bandwidth() {
    local upload download
    local -a options=()
    printf '\n%s\n' '填写客户端速率，单位 Mbps。0 使用自动拥塞控制，留空沿用原设置。'
    read -r -p '上传（客户端 → VPS）  ' upload || return 1
    read -r -p '下载（VPS → 客户端）  ' download || return 1
    if [[ -n $upload ]]; then
        options+=(--hysteria2-up-mbps "$upload")
    fi
    if [[ -n $download ]]; then
        options+=(--hysteria2-down-mbps "$download")
    fi
    if (( ${#options[@]} )); then
        install_stack --yes "${options[@]}"
    fi
}

guided_hysteria() {
    backend_ready || return 1
    printf '\n%s%s%s\n' "$title_color" 'Hysteria2 设置' "$plain"
    menu_item 1 '端口跳跃'
    menu_item 2 '上传 / 下载速率'
    menu_item 0 '返回主菜单'
    local choice
    while read -r -p '请选择 [0–2]  ' choice; do
        case $choice in
            1) ask_hop; return $? ;;
            2) ask_hysteria_bandwidth; return $? ;;
            0|'') return 0 ;;
            *) printf '%s\n' '请输入 0–2。' ;;
        esac
    done
}

valid_shortcut() {
    [[ $1 =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,15}$ ]]
}

shortcut_script() {
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$manager"
}

shortcut_taken() {
    [[ -e $shortcut_dir/$1 || -L $shortcut_dir/$1 ]] || command -v -- "$1" >/dev/null 2>&1
}

get_shortcut() {
    local key
    [[ -f $shortcut_record ]] || return 0
    IFS= read -r key < "$shortcut_record" || return 0
    valid_shortcut "$key" || return 0
    [[ -f $shortcut_dir/$key && ! -L $shortcut_dir/$key ]] || return 0
    cmp -s -- "$shortcut_dir/$key" <(shortcut_script) || return 0
    printf '%s\n' "$key"
}

shortcut_command() {
    local key=${1:-} old target pending launcher
    old=$(get_shortcut)
    if [[ -z $key ]]; then
        printf '当前快捷命令  %s\n' "${old:-未设置}"
        return 0
    fi
    if [[ $key == --remove ]]; then
        mkdir -p -- "${shortcut_record%/*}" || return 1
        pending=$(mktemp "${shortcut_record}.XXXXXXXX") || return 1
        if ! printf '\n' > "$pending" || ! mv -fT -- "$pending" "$shortcut_record"; then
            rm -f -- "$pending"
            return 1
        fi
        if [[ -n $old ]]; then
            rm -- "$shortcut_dir/$old" || return 1
        fi
        printf '%s\n' '已取消快捷启动。'
        return 0
    fi
    if ! valid_shortcut "$key" || [[ $key == hrules-six ]]; then
        printf '%s\n' '请输入 1–16 个英文字母、数字、下划线或连字符，首字符用英文字母。' >&2
        return 1
    fi
    if [[ $key == "$old" ]]; then
        ensure_manager || return 1
        printf '已设置  输入 %s 回车打开菜单。\n' "$key"
        return 0
    fi
    target="$shortcut_dir/$key"
    if shortcut_taken "$key"; then
        printf '快捷命令 %s 已被占用，请换一个名称。\n' "$key" >&2
        return 1
    fi
    ensure_manager || return 1
    create_command_directory "$shortcut_dir" || return 1
    mkdir -p -- "${shortcut_record%/*}" || return 1
    pending=$(mktemp "${shortcut_record}.XXXXXXXX") || return 1
    launcher=$(mktemp "$shortcut_dir/.hrules-launcher.XXXXXXXX") || {
        rm -f -- "$pending"
        return 1
    }
    if ! printf '%s\n' "$key" > "$pending" || ! shortcut_script > "$launcher" ||
        ! chmod 0755 -- "$launcher" || ! ln -T -- "$launcher" "$target"; then
        rm -f -- "$pending" "$launcher"
        return 1
    fi
    rm -f -- "$launcher"
    if ! mv -fT -- "$pending" "$shortcut_record"; then
        rm -f -- "$pending" "$target"
        return 1
    fi
    if [[ -n $old ]]; then
        rm -- "$shortcut_dir/$old" || return 1
    fi
    printf '已设置  输入 %s 回车打开菜单。\n' "$key"
}

initialize_menu_shortcut() {
    if ! ensure_manager; then
        printf '%s\n' '菜单启动文件写入失败，可在菜单 12 重试。' >&2
    elif [[ ! -e $shortcut_record && ! -L $shortcut_record ]]; then
        shortcut_command m || printf '%s\n' '可在菜单 12 设置快捷命令。' >&2
    fi
}

ask_shortcut() {
    local key
    shortcut_command || return 1
    printf '%s\n' '例如输入 m，之后在 SSH 终端输入 m 并回车。'
    read -r -p '输入快捷命令（输入 - 取消，留空返回） ' key || return 1
    case $key in
        '') return 0 ;;
        -) shortcut_command --remove ;;
        *) shortcut_command "$key" ;;
    esac
}

menu_heading() {
    printf '\n  %s%s%s\n' "$accent" "$1" "$plain"
}

menu_item() {
    printf '  %s%2s%s  %s\n' "$accent" "$1" "$plain" "$2"
}

menu_note() {
    printf '      %s%s%s\n' "$dim" "$1" "$plain"
}

guided_update() {
    printf '\n%s%s%s\n' "$title_color" 'GitHub 脚本更新' "$plain"
    run_installer update --update-action status || return 1
    printf '\n'
    menu_item 1 '立即检查更新'
    menu_item 2 '立即更新'
    menu_note '安装新版时，代理和订阅服务可能短暂重连'
    menu_item 3 '设置自动检查'
    menu_note '定时只检查更新，由你决定何时安装'
    menu_item 4 '查看在线安装命令'
    menu_item 5 '设置每日自动安装'
    menu_note '等待设定时段，有新版才安装'
    menu_item 6 '重新应用上一版'
    menu_note '回退时暂停自动安装'
    menu_item 0 '返回主菜单'
    local choice hours schedule_time
    if ! read -r -p '请选择 [0–6]  ' choice; then
        return 0
    fi
    case $choice in
        1) run_installer update --update-action check ;;
        2) run_installer update --update-action apply ;;
        3) read -r -p '检查间隔（小时，回车 24，输入 0 关闭）  ' hours || return 0
           run_installer update --update-action schedule --update-hours "${hours:-24}" ;;
        4) printf '%s\n' 'bash <(curl -fsSL https://raw.githubusercontent.com/SUYUEM/Hrules-install/main/install.sh)' ;;
        5) read -r -p 'VPS 本地时间 HH:MM（回车用 02:00–02:59，输入 0 关闭）  ' schedule_time || return 0
           run_installer update --update-action daily --update-time "${schedule_time:-default}" ;;
        6) run_installer update --update-action rollback ;;
        0|'') return 0 ;;
        *) printf '%s\n' '请选择菜单上的数字。' ;;
    esac
}

draw_menu() {
    local key notice
    key=$(get_shortcut)
    printf '\n%s%s%s\n' "$accent" 'Hrules  协议服务管理' "$plain"
    printf '%s%s%s\n' "$dim" '────────────────────────────────' "$plain"
    printf '  快捷启动  %s\n' "${key:-hrules-six}"
    if [[ -s ${state%/*}/github-update-status.json ]] &&
        notice=$(run_installer update --update-action notice 2>/dev/null) && [[ -n $notice ]]; then
        printf '  %s%s%s\n' "$title_color" "$notice" "$plain"
    fi
    if [[ -z $key && ! -e $shortcut_record && ! -L $shortcut_record ]] && shortcut_taken m; then
        printf '%s\n' '  m 已被占用，可在菜单 12 修改快捷命令。'
    fi
    menu_heading '部署与订阅'
    menu_item 1 '安装 / 更新协议服务（含节点管理）'
    menu_item 2 '查看服务状态'
    menu_item 3 '订阅链接和二维码'
    menu_heading '流量管理'
    menu_item 4 '查看累计用量'
    menu_item 5 '修改流量上限'
    menu_item 6 '清零已用流量'
    menu_item 7 '调整采样间隔'
    menu_heading '服务与工具'
    menu_item 8 '启动代理服务'
    menu_item 9 '停止代理服务'
    menu_item 10 '重启代理和订阅'
    menu_item 11 '查看最近日志'
    menu_item 12 '设置快捷启动'
    menu_item 13 'Hysteria2 设置'
    menu_item 14 '出口代理管理'
    menu_item 15 'GitHub 脚本更新'
    printf '\n'
    menu_item 0 '退出'
    printf '%s%s%s\n\n' "$dim" '────────────────────────────────' "$plain"
}

menu() {
    if [[ ! -t 0 ]]; then
        usage
        return 1
    fi
    initialize_menu_shortcut
    local choice
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
            printf '\033[H\033[2J'
        fi
        draw_menu
        read -r -p '请选择 [0–15]  ' choice || return 0
        printf '\n'
        case $choice in
            1) guided_install ;;
            2) show_services ;;
            3) run_backend links ;;
            4) run_backend quota ;;
            5) ask_limit ;;
            6) ask_reset ;;
            7) ask_interval ;;
            8) backend_ready && systemctl start "$core" && show_services ;;
            9) backend_ready && systemctl stop "$core" && show_services ;;
            10) backend_ready && systemctl restart "$core" "$subscription" && show_services ;;
            11) backend_ready && journalctl -u "$core" -u "$subscription" -u hrules-six-hysteria2.service -u hrules-six-traffic.service --no-pager -n 60 ;;
            12) ask_shortcut ;;
            13) guided_hysteria ;;
            14) run_backend outbound ;;
            15) guided_update ;;
            0) return 0 ;;
            *) printf '%s\n' '请选择菜单上的数字。' ;;
        esac
        read -r -p '按 Enter 返回菜单 ' _ || return 0
    done
}

online_bootstrap() {
    if [[ -f $state || -f $landing_state ]]; then
        run_installer update --update-action apply || return $?
    else
        install_manager || return $?
    fi
    if [[ -t 0 ]]; then
        exec bash "$manager" menu
    fi
}

case ${1:-menu} in
    menu) menu ;;
    online) online_bootstrap ;;
    install) shift; initialize_menu_shortcut; install_stack "$@" ;;
    landing) shift; initialize_menu_shortcut; run_installer landing "$@" ;;
    node-suffix) shift; edit_node_suffix "$@" ;;
    status|links|quota|traffic-interval|outbound|nodes) run_backend "$@" ;;
    shortcut) shift; if (( $# <= 1 )); then shortcut_command "$@"; else usage; exit 2; fi ;;
    update) shift; if (( $# )); then run_installer update "$@"; else initialize_menu_shortcut; guided_update; fi ;;
    *) usage; exit 2 ;;
esac
exit $?
: <<'__HRULES_BACKEND_END__'
__HRULES_BACKEND_V1__
21ef9527300ff3b10e99f25e4c5220b027cd3b44c413993c0ec9a8b87c073d4e
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
__HRULES_BACKEND_END__
