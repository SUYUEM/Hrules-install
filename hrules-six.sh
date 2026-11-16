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

initialize_manager_updates() {
    local setup=${state%/*}/github-auto-update-setup
    if [[ ! -f $setup || $(<"$setup") != configured ]]; then
        if ! run_installer update --update-action init-auto >/dev/null; then
            printf '%s\n' '自动更新初始化未完成，下次打开脚本时会重试。' >&2
        fi
    fi
}

install_manager() {
    local pending
    if [[ -x $manager ]] && cmp -s -- "$self" "$manager"; then
        initialize_manager_updates
        return
    fi
    create_command_directory "${manager%/*}" || return 1
    pending=$(mktemp "${manager}.XXXXXXXX") || return 1
    if ! install -m 0755 -- "$self" "$pending" || ! mv -fT -- "$pending" "$manager"; then
        rm -f -- "$pending"
        return 1
    fi
    initialize_manager_updates
}

ensure_manager() {
    if [[ -x $manager ]]; then
        initialize_manager_updates
    else
        install_manager
    fi
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

guided_auto_update() {
    local window detection
    read -r -p '更新时段 HH:MM-HH:MM（回车 02:00-02:59，输入 0 关闭）  ' window || return 0
    if [[ $window != 0 ]]; then
        read -r -p '检测间隔小时数或每日 HH:MM（回车 24 小时）  ' detection || return 0
    fi
    run_installer update --update-action configure-auto --update-time "${window:-default}" \
        --update-check "${detection:-24}"
}

guided_update() {
    printf '\n%s%s%s\n' "$title_color" '脚本更新' "$plain"
    run_installer update --update-action status || return 1
    printf '\n'
    menu_item 1 '检查并更新'
    menu_item 2 '自动更新设置'
    menu_item 3 '恢复上一版'
    menu_item 0 '返回主菜单'
    printf '\n%s\n  %s\n\n' '在线安装命令' \
        'bash <(curl -fsSL https://raw.githubusercontent.com/SUYUEM/Hrules-install/main/install.sh)'
    local choice
    read -r -p '请选择 [0–3]  ' choice || return 0
    case $choice in
        1) run_installer update --update-action apply ;;
        2) guided_auto_update ;;
        3) run_installer update --update-action rollback ;;
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
    menu_item 15 '脚本更新'
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
        initialize_manager_updates
    else
        install_manager || return $?
    fi
    if [[ ${1:-} == settings ]]; then
        exec bash "$manager" update settings
    fi
    if [[ -t 0 ]]; then
        exec bash "$manager" menu
    fi
}

case ${1:-menu} in
    menu) menu ;;
    online) shift; online_bootstrap "$@" ;;
    install) shift; initialize_menu_shortcut; install_stack "$@" ;;
    landing) shift; initialize_menu_shortcut; run_installer landing "$@" ;;
    node-suffix) shift; edit_node_suffix "$@" ;;
    status|links|quota|traffic-interval|outbound|nodes) run_backend "$@" ;;
    shortcut) shift; if (( $# <= 1 )); then shortcut_command "$@"; else usage; exit 2; fi ;;
    update)
        shift
        if [[ ${1:-} == settings && $# == 1 ]]; then
            initialize_menu_shortcut
            guided_auto_update
        elif (( $# )); then
            run_installer update "$@"
        else
            initialize_menu_shortcut
            guided_update
        fi
        ;;
    *) usage; exit 2 ;;
esac
exit $?
: <<'__HRULES_BACKEND_END__'
__HRULES_BACKEND_V1__
cd4b9b948cbb0938db2d086ecfda753635db007e6ecb060375192cb8d43700e0
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
__HRULES_BACKEND_END__
