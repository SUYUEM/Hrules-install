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
    printf '%s\n' '用法  sudo bash hrules-six.sh [install|landing|node-suffix|status|links|quota|traffic-interval|outbound|nodes|shortcut|update|bbr3|system-update|ssh-defense|reality-vision] [选项]'
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
    menu_note '启停节点或更换监听端口'
    menu_item 6 'REALITY Vision 握手网站'
    printf '\n'
    menu_item 0 '返回主菜单'
    printf '%s%s%s\n\n' "$dim" "$divider" "$plain"
}

guided_install() {
    local choice
    draw_install_menu
    while read -r -p '请选择 [0–6]  ' choice; do
        case $choice in
            1) install_stack --profile recommended; return $? ;;
            2) install_stack --profile custom; return $? ;;
            3) run_installer landing; return $? ;;
            4) edit_node_suffix; return $? ;;
            5) run_backend nodes || :; draw_install_menu ;;
            6) run_installer reality-vision; return $? ;;
            0|'') return 0 ;;
            *) printf '%s\n' '请输入 0–6。' ;;
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

apply_menu_update() {
    local action=$1 running installed
    running=$(sha256sum -- "$self") || return 1
    run_installer update --update-action "$action" || return $?
    [[ -x $manager ]] || return 0
    installed=$(sha256sum -- "$manager") || return 1
    if [[ ${running%% *} != "${installed%% *}" ]]; then
        read -r -p '按 Enter 返回主菜单 ' _ || return 0
        exec bash "$manager" menu
    fi
}

guided_update() {
    printf '\n%s%s%s\n' "$title_color" '脚本更新' "$plain"
    run_installer update --update-action status || return 1
    printf '\n'
    menu_item 1 '检查并更新'
    menu_item 2 '自动更新设置'
    menu_item 3 '恢复上一版'
    menu_item 4 '关闭自动更新'
    menu_item 0 '返回主菜单'
    printf '\n%s\n  %s\n\n' '在线安装命令' \
        'bash <(curl -fsSL https://raw.githubusercontent.com/SUYUEM/Hrules-install/main/install.sh)'
    local choice
    read -r -p '请选择 [0–4]  ' choice || return 0
    case $choice in
        1) apply_menu_update apply ;;
        2) guided_auto_update ;;
        3) apply_menu_update rollback ;;
        4) run_installer update --update-action configure-auto --update-time 0 --update-check 24 ;;
        0|'') return 0 ;;
        *) printf '%s\n' '请选择菜单上的数字。' ;;
    esac
}

guided_bbr3() {
    printf '\n%s%s%s\n' "$title_color" 'BBRv3 内核管理' "$plain"
    run_installer bbr3 --bbr-status || return 1
    printf '\n'
    menu_item 1 '安装 / 更新 BBRv3 内核'
    menu_item 0 '返回主菜单'
    local choice
    read -r -p '请选择 [0–1]  ' choice || return 0
    case $choice in
        1)
            run_installer bbr3 --bbr-update --yes
            read -r -p '按 Enter 返回主菜单 ' _ || return 0
            ;;
        0|'') return 0 ;;
        *) printf '%s\n' '请选择菜单上的数字。'; return 1 ;;
    esac
}

guided_ssh_defense() {
    local choice action
    while true; do
        printf '\n%s%s%s\n' "$title_color" 'SSH 防御（Fail2Ban）' "$plain"
        run_installer ssh-defense --ssh-action summary || return 1
        printf '\n'
        menu_item 1 '安装 / 启用防御'
        menu_item 2 '查看 SSH 封禁'
        menu_item 3 '实时日志（Ctrl+C 返回）'
        menu_item 4 '设置封禁参数'
        menu_item 5 '编辑防御配置'
        menu_item 9 '移除 Hrules SSH 防御'
        menu_item 0 '返回主菜单'
        read -r -p '请选择 [0–5、9]  ' choice || return 0
        case $choice in
            1) action=install ;;
            2) action=status ;;
            3) action=logs ;;
            4) action=configure ;;
            5) action=edit ;;
            9) action=remove ;;
            0) return 0 ;;
            '') continue ;;
            *) printf '%s\n' '请选择菜单上的数字。'; continue ;;
        esac
        printf '\n'
        if run_installer ssh-defense --ssh-action "$action" && [[ $action != logs ]]; then
            printf '\n%s%s%s\n' "$title_color" '操作完成' "$plain"
        fi
        read -r -p '按 Enter 返回 SSH 防御菜单 ' _ || return 0
    done
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
    menu_heading '系统工具'
    menu_item 16 'BBRv3 加速'
    menu_item 17 '系统软件包更新'
    menu_item 18 'SSH 防御'
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
        read -r -p '请选择 [0–18]  ' choice || return 0
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
            16) if guided_bbr3; then continue; fi ;;
            17) run_installer system-update --yes ;;
            18) if guided_ssh_defense; then continue; fi ;;
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
    bbr3|system-update|reality-vision) run_installer "$@" ;;
    ssh-defense) shift; if (( $# )); then run_installer ssh-defense "$@"; else guided_ssh_defense; fi ;;
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
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
__HRULES_BACKEND_END__
