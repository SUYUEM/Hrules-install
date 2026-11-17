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
    printf '%s\n' '用法  sudo bash hrules-six.sh [install|uninstall|landing|node-suffix|status|links|quota|traffic-interval|outbound|nodes|shortcut|update|bbr3|system-update|ssh-defense|reality-vision] [选项]'
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
    printf '\n%s%s%s\n' "$title_color" '脚本更新 / 卸载管理' "$plain"
    run_installer update --update-action status || return 1
    printf '\n'
    menu_item 1 '自动更新设置'
    menu_item 2 '恢复上一版'
    menu_item 3 '关闭自动更新'
    menu_item 4 '一键卸载 Hrules'
    menu_note '停止服务并删除节点、订阅和流量记录'
    menu_item 0 '返回主菜单'
    printf '\n%s\n  %s\n\n' '在线安装命令' \
        'bash <(curl -fsSL https://raw.githubusercontent.com/SUYUEM/Hrules-install/main/install.sh)'
    local choice
    read -r -p '请选择 [0–4]  ' choice || return 0
    case $choice in
        1) guided_auto_update ;;
        2) apply_menu_update rollback ;;
        3) run_installer update --update-action configure-auto --update-time 0 --update-check 24 ;;
        4) run_installer uninstall && exit 0 ;;
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
    menu_item 2 '服务状态与故障自查'
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
    menu_item 15 '检查并更新脚本'
    menu_item 19 '脚本更新 / 卸载管理'
    menu_heading '系统工具'
    menu_item 16 'BBRv3 加速'
    menu_item 17 '系统软件包更新'
    menu_item 18 'SSH 防御'
    printf '\n'
    menu_item 0 '退出'
    printf '%s%s%s\n\n' "$dim" '────────────────────────────────' "$plain"
}

menu() {
    initialize_menu_shortcut
    local choice
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
            printf '\033[H\033[2J'
        fi
        draw_menu
        read -r -p '请选择 [0–19]  ' choice || return 0
        printf '\n'
        case $choice in
            1) guided_install ;;
            2) run_installer diagnose ;;
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
            15) apply_menu_update apply ;;
            16) if guided_bbr3; then continue; fi ;;
            17) run_installer system-update --yes ;;
            18) if guided_ssh_defense; then continue; fi ;;
            19) guided_update ;;
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
    menu)
        if [[ ! -t 0 ]]; then usage; exit 1; fi
        menu
        ;;
    online) shift; online_bootstrap "$@" ;;
    install) shift; initialize_menu_shortcut; install_stack "$@" ;;
    landing) shift; initialize_menu_shortcut; run_installer landing "$@" ;;
    node-suffix) shift; edit_node_suffix "$@" ;;
    status|links|quota|traffic-interval|outbound|nodes) run_backend "$@" ;;
    bbr3|system-update|reality-vision|uninstall|diagnose) run_installer "$@" ;;
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
20d8ff709193d8d856de282c3e60d9574fbaeadc2cef0bee48ee5368efbaa3bd
H4sIAAAAAAACCrS9aXsbx5Uw+p2/ooO8MwZE7BuXN0wGJEESXAAQAEmRNAdPA2gQTQJoEN0gCdK8j5yJbMu2LCXxEtvyltiO49iSkji2bHl5nvtTZgQun/IXbp1auqsXgHQmV3EkdHctp6pOnTrn1Fl++pNAR20HSnIzIDX3hVZXqynNyJDL5Zprd+qSKjQ6dU32tdqKppSVurCazQtyU9XEel1qC2KzIrTa8r6oSYLaKanlttzSZKUpqFJ7X2r7UTNDQ3KjpbQ1QWxvt8S2KrHnkqhK8aj+JDdFtSzLQ9W20hDKSrPcabelpuavdrROG8FByxVqbUmsZBWlnjyUyh1Naes1NOlQq8slVpK+aYhNcVtqe4Vmp16n7/QqVZnA1GaVpvC7LH7nFZLttoIGqdLX+JHUrUhluSHWWbVp8ki+bUtaS1R1iGclLYse18R2U25ue9lnNvDtI7nFftdEtYZGoD82xLL+W9Na/nJdRlNiekUmmnQsK6zPya4mqamMV8hrbdRpKsPqyC2xUkHTqXe/oypN9ltRSTstUatxE5lFj6xIqy5qVaXdYM9tfTlVqdyWNL1dNBDp0HjoaHJdf1LKu5I+ClWl04ZwSpNVTS7rM9eQKrKoQ6dq7U7ZqNYpIZwscyNRu/pPTWxX5boOmiY1WqZnjENoXvQXckMiQHTadTRyP0YKBsZeR9Ekr9Bpsh/tutQsKxVzFQnjCq0yVyhkMbZ4hZXcIoc3tHBb2utIqsYXz6HBtqWyNof2VB2QL0fKeIVSR65XikpLaqKFpjU6HbnCfh9xKHNAsEwdGprK5JLF1WQun8qkhQnBtR/yh8b8kahrKL8ynVlYMX0L+mP+sC/kGppbzxeSuVTC9DXsD0X9Qe5jIp9PFvLo2/GQgP64xEYlHnWNC65qORyTKtXq2Fh0dCQ4Wi4Fg2K0Wg2GqpFSuVyR4iMj8XhQLIvBWDAUiZRKIbESjZfjo/FgJB6uhF1e2mC7QRqURsqxcDgaCo+NVaXRmFgSQyFprBKJo4fKaGV0tFIplWIjY2NiOShFIpXwSDgcGquE0UMoUhJLqMETMhX9YHaTX76y0kB4L5fqkssruMIj8Ug1VoqGorHwSHWkJFbjlXJsRIpUR8PViFiKxUMSGmgkWqpWRsrhahgNLlQdkWJjYakqBeMuj2UkbvoLtV0RxerIqBgPR4NieBTVRE3ESuVSdWy0KkXCoWq8VEG9xmPlcnhMGhlDvURDY6EQ+hwsxYJVaPtkKJdMLKYK68W5TL4Aq3RwcIDog9KpVOtiW/Kj4biGVlNsDRFlVH3tVvvQty+riEC7hrKZXKGYzWUKmanMIjcvta6qSW1ZDGOgO5WWy+tBQGsduWx+05Cldge/0sr0ldqpKLumd3QSml3Uv7nsPjpcLK/4ZwF3BG8Pgc7Z29Tayo7YtDTQlOp186vtdqtsBdI4p0zNngxNJ2cSK4toWtDc4CkxzUY0GjEmYpQ8sVGgJ6N6LpGezizprbTF5rbkDgfRH68QR3+HPGwPOpaMQRFUMhaLxD1DS6lkbqW4mEJbL20pGAqGY3q5dGY6aW3v2FgRhw65NbR3YoxmLpPVG3QhnA0GfejvUMxlKpFKI9KwmlhEhSJBAkw6sZTsg1iuOf3BmFJXYSU1JezHXBxgriX4IRSmsow06CNykSFBaR2/XIlmt7CYd3Er41pdTObzAt0uwipBf9YYLpGviRXlAI4l1cUhHK15HagzBpNhnKtAfrFGKNa58vBD2MebnOKdpfftXHbKRTEtmcslp4swUzBJbta8jsasEc9QKrsaL2bSi+tcaWuZxeRsYsoooHVadcndFBuSgI5rAf+QmwK3LnKVvG0qGnwxA+RB5GUqs7SUTE9zMP7oRo9hgo2ZO0F4n0eYMplZSU8Xp1LZuWQOkKpcE9F/4aBPlrSqr6XUu6FIEOEXwcolhGKp7GLyeio9C6X55+JiZo2Vm0OonZ9LLCSLSwggKGm8yRfQz0RuGh1+hUQhWZxOQcfA2LhdgX2xHUBHaKCGGV6fKh+i+cytpAuppaRRCrjkulIW6/ayqTRqdXExOY1Ks3oBhPB6GX+ri6BMpBOzyZxTiyqw36Ym83Nox02tFMyQGjVQBVRqJTsNo8klsxkYb35lfSW5FCCMu49y6S5WCjEiqFDVBditjgcCYkv2b8tarVOCwyLQllqKGjjmmjwJYHa5qakcbH619ou2VJ1oiAgCA4A8WhTUujG7aPykcV+nVUHigQ/Yu47qB35Tr7eYmVoYWMuPRrurF59MTC2sZAd302pL+7KCOlJrej108PetJiIRQgdRQhjO1cqtpqYwIhnDZ0XLNam8i5lvuSzpVWDlc4MqAKPZdg0lVgqZ4sBuOLCMXvhqTl3xlVhPWQsKSVoZrbyGkOd6Io02SjGTS82mMI9QkUr+Q7HZUCp+pb3tYgUWkutFtIvCsTgUkirhuFSKjEUiwWolPBYvV4KRkdJoODwmVsplSQyGxkZKiAUbHZPKQRHYu2q0OhKtxsRoqDwijriGJidzxfx6fqqwaIYK8e9lre6vBMbGfHRQpVJ7P+IHOQ3Bi+slCwW07cnZ1pQ09A3xOhWpKiIptbhXkVVMdKt7QHXgu9zaj/rRAV9EjWwjbhrRfviJCBKm2KgD18nQTCK1GJ5MpO0zVRXlergkwl7TCy1mZi20Q9nWCyKE3Ybtm58rAkVN55PFzFoar5QJ+1S15kNgS01VYhtVqrhM9ejpSsaKmoYVBZhDNRhcVW5W9DfBBj4zxUMkgbW78CrmImyvmSI15JrSUAxG3vS1qp/QvmOrGHDCpAZze+Qs9kmHIHsAuuEx2saqAUKSjZ9ZsZEJnh9TXYRZRyiesJZjwBcwt2oUQ5/g8Dekk6lMeiY1ay2jsx8UkjwUX5q24SASFiv0X1hIsjuLdC753UbgMXYnK5pfmbSU5EdoLz+zZileRXLgAUIIe9FCLjEzg3gkc3mtLVarctlefBEdevTQ5IrXkYCJRER7cQ4r+PLGxOk19KmezKWmZ9HRkjfRIlbDNZROFFKrRsvFmVRycRrLI2yLN5HMtS8ZnbiGKNSOOEBhNwoxhDNVsuAc+zaXXMxiOB3PaH1e4KymE+1IZdl0UwrLijIGmO1bVCtm/wi4CYOiyAe77tjU2Ym/4gLAZHTytvfFOqF+Q8bKm+aDwUIGyhpyOlZZSXKgIjAKucxiMY9KJgu2rUIGS+mkX8VV0M4lfBtwepi7IqV6z3/Tu/MH7nthPZukwocTd41/xPAH1Hkec/uM4QZOG4GSTienCoiAIWaRMImY5SXMdh9eEYQABEwoPOrbLjfYIzqzyCOpGw6Gw75SXdyVIj5Laesnvab5k9670fGQxxh6KuuA4Yg6SmVNqqAfsuaTW9xUTabQX/YaSkcrKZ1mBZ0M+F+uBlpatKUy6UG1gEPEwu1QMp2YXGQMvBNoTbGEzh1fU6lIiILm08nFxWJiehrxc3nHCljq8FEVIq6C0DqZQwzgPFqyYm5lMcmtVSrrm0pN57xBP/5fYNRLysGssm8h+0dz5VAw6I9HcZFQ0KmB8MhlLcTH/OEYbSLu1MRI2B+Kk+/hfo2MQZnR/o2Ew1EKR7RPE0hqtpXQv8a94+Oo9z5jgK8h02fuU7UcDKLKI/2qVqVR+O40e+hjFVfm+vUMIdGqgCgVopK5FC/BT6Vhkz559Hnv7e96H/7x4s3noKm5BXh78fGbp48ewPNSBp5Pv//bxRufwHNhDZ57dx6efv09PM9n8fc3Pjq99xk8L+Rw/ff+hFplsOdncZnXH/ZefL/3zge42XVc7E+fnb7z0flHPzz55i3c+Bwu+LeHuDIStzGI51++2Lv9Bh7nNO789sPeNx/3Hn5rVMziiud3/tr7/qXe/e/1SUsb5aFYYoUOBo2398KfaOX0BgUPtde7+RBereTh1dn3r1BAphK4oRffP33pB1QXj+A6fvX7T6DWbz9iXU7i8fe++gK9xl2S+fjdD6fvf917/BW8mp3EwL70F9r4dBJX+f4r+jyTI7PwGn1OL+Lyt7/CwJFukhhA1MfZnc/Pbr2JJ6eAq/3qDhkcBhtPy9mv3+394c/wnE+y55uPcE8p3MqLn9FhZxdJz7/nesrhOXvyw6/Ovnvj9HWMEwUyxnvvnd/4W+/ml3iYSTrM82dfvbj5ErzaIHN2+42Ld97FWhKCiKmCCQvriiqA+gvRI9z3F2+fvnPr7D3cqCo2hR1FlUhvf3jy3Wu9D95lH6ptsVlGEoJC8O+PF8//uveXv+CvkqhpdYlO0MXbN3tv6xjRlA6ErtLexfPwzXdnBC/YW6Esa13zpwpi3UQM2vn335++dItOQbkml8VthUzfO4DXBgrUlWYFKyNdT779+PQ13AxAu1vtwMVZQ8DSNl3imw97N186+/gOFGqJbVml6HPx+BV87jWAk6qIDTq9vT8+hyA4u/X1k0dfs/40ZberkL1878k3eBcqqrgr4pbQxv7dp2RWlE6d7O3Xew9fhVe7HbEuCvVOo9Vp48J3b1289RzeoVQXhjgoEUkDkm3/1pAAJuyiv8zUQhPlliRTCtF7GW9atVtpSnhWT395C+1aXE5pI3ZEIRC+haYJ/U2U+4uZlemZxQTiXwBdsHJsSteDM+4CFB52DXmgXGn6yttyAHFHiK8FTVsqPZMxGkpl5WZV4RuRW/DGLysBzHPpyh/GdLkC7Q6vy2HSHWW8QFU6k8ol11AVK4um88CGBED4urlMZsEsp9QlTZWa5Xa3pQXaUhMK+2qKsqsGKlKrrnQDo0GfSZ80lcwhDsJBF8C1hIoVMgtJ4C0WKQdHZZyu2MC6Rswn+LVDTX/wkVtc9g6W31dSDgngTJVJ6p8MDf1UKNQkoY22LqoliG1NroplTZAaJamiChr6hrVbAr16RjKu5NtuI9yXKoLaFFtqTdGEmoQWbyiHWCIsAKQT2fxcBl+BzEXVVIL8mQqMhsT1tUDpsNYcjtTHDg8W4/l6Jri7s6ftb29kwgctsS5PBrdzhWRqPpDanVspSEuFo/zOfmk+Xpqqq8Od3Xypu51f7zTC6wehqenU7uFGabW8EdH2D7prpbmxvWpwsZrqrs4sNetzk3vR2VR9clsuD4+NBLLlUWlE6gSqoUQkPiaOrE/N7TfkYSU+P5vdSM1UI0Exox1VlnabIzMH6WrlaERsVwPRbHM/sptURrLtg5XJqevhqZnRVvkwnIpK6+G51fTc8OFyak9RpqdS3Y1ONZcO7+QO1xPx3Y1IILtamxuJZKXydj3ejMgrwVymG253Z472d4fXFjqHu4vbnVJuprF7mBX3s+r0thaNhxe1wOjs8nSoHKtmFmZjI9V9RcxEageV9YJYuh4IrW3sB6rJ+cXKyMi0HCkc7SzuN9PTmXp0LBBZbKQXW6llJZrVAoG8FNEi1U5ldWSsEpCa1bXCWCdxpCWOoqtKYmxHXK2JgZ1CbnJM2m8WQkpA3h8dub44cyhen4q04yNz2ZVqoD5WCqjDU+mdamQj3tW6o5GN9XJ6bjY+NpKN1AuhdLizuDY/jXA2U93ZXa2O7YuB8PXZUDZc2d/fj2d2pP2D0Wo1Vhqp70fzkcbIMOp+f2Uu0JTWAkdL4t52oBKe25fCzcl4YD+RKrc6IyORhUJrtLqXjcSX49FadbiZjcYigWgzvjYaiFQD21Nzk7HhQLwQCR2NliOlw6Ph7PWGlg4PL6fK2bn99chcLTIcH9uXjpRgSzrsaIeIH54JBaXMKoJrWN0YVmpz3dDsdCGrhcLrK7FqMNPZQf0Xru8nx7ZL+7lwYCw+Fq0248n6zrzUGMkulmbickRDWFNdqwQ2hrMHaNYCoehiJTwWzkvD88H9Qqi8HEBPI1ONkcWAmMm2OtOR0KiUzbaClb1qNTSzvx+cX4xMZZXQzPWj/HZY201OLh9tLy/ImTF5Knl9VC0llnZS8vJ6ono4vz+fCi4sqLVyKjyaPwqKwfnR4Xx5fSooFyanFxbKuZS4MBtty4WNdGNkaXnlQMwuzS0lFsoLibA8MzpdaExtRDYSy/tTqdnryVz0IJoL7W23EUVaKA1vTMYmF2PBg1ZoeX5RrbdLo/ny5H4lsTZ3OJdTEtOl3e343GqlthMfrZRnRWlptass7an1oDq5uHY4GwhIsdTs3EG3vbcuB2Kp5Xa5Nd9QVmVl8np7VUzPHs7trMjLy0mlvriYU0fq10Wtfpi+nu4q1cnJo725neWp3FpWazfnFkZTjem5qBhcQEfJQjc3dTg8N5Lf6y7IS628vDxTG00uTO5uHKmBpaOl8OhKJpyf6aQPEK/RPFiVNrojqZ18dzJ2uBcdjsZLuXa0rGTWp3Ll2Mrc3HRmdmYhGukmxEZ8fmGt0EyFCmJtLTmVa+dnNrYL2nROzMULe43MXnCjk1lZ60Si2ZlyQ1lu7MzNr2ykFq4nV5tHqcX5bLI2M5s5THSXV+SFhjo1GlXnpfXg4npwaWdWm48f7R0klebq8tzKztT2TuJ6aTEtLh+2KgeHBTG7snKUVYblZERdixzJ86vN4EpICS1LQW0+vbK9ury3oxQ2DhYOdiLDme7eeixZXZnS5LlUZW2vMRzJN7ThZqlZqhTawWQ7tLM+GVmfjQfzmWZyJ7a9GhSjkwvxlchCObvUas5PLsSawWRpSQ7urG63ri93poNqciq2lJgvbGfD0vWN/fXSSlxO72X2k3Ftur08nchMZQvNWlaaX74+H1svj8rtuf1svtZS9/Zm5oP1YLkWSUsrhexCYrUU255cTbTS8Xxld66y0NpZr9Xzo+HZeHUlvpsUD3K5cnt7tr6bV2KhXDqT2VvbWMqubU/vpEqxXHM5kZ/T1hfWD+LKSmtEkbvtFeVwDyHgiryRSYY3jhJScm46PnW4UEisza/vBbdXd8fWV8XrR9nCpFZbUJt7Y+uR3dLCZKE7PCx11jbGFjJyenVnXdvb2BvN7+2Mqt3c2mz4ejqqBFdSq7txpdlazM/FVg7LO/X1eL2mRKKFVGx+6nohuxI/mKtll0YO0pVG7Gh4No3GNlqYiazOh7vZqYVMY2NdS0rBncpyOzW1XyqURtJT9SN5IzqFlqEerE8tHSZWIsroweJhen9+d6G8Ik+matejsempuYXlbHmyFqgtq9uLO2MHy8FOYv9oLdi8PjubVTdGJtOr8625eCabaZdCiUZjUQnEc+XV3PXurnqobu+19jPXF1vxdqCyUe7sL0rSyFo7V1vIyzulyG53dbk7tZbQ8sux9dhUa2lsrr4wMhxbn4pV1qbXu8nQ+nRzKRk9mgtMRnJr+VFlvhJWE+nFhZCYbmo7naxY66xuj1TH6uuNxeuZo3rraCN+tLESLu+1hte7i8vxQ/UovRZYGO7uJjIlVdrIHo5Ob8wWQt2RxsGhHMjuJ9S1ye713bGxTLecLnSqKXRW7E91clPBtaUjNVyZ20+MtstSJbOWSVevL8bLY3FltSFNxtZTUmgx19zYa692td3yzExjeWEuPJeIH2zMhlRlNCNG5yZLqXStWmvEyo1EfHJUnm+Er5dS63tTUwe1ydTi5FFsLSGlYodaAZ2dI9FMJ7O3cRirtFaC8cyylC2s7ldjG9Nqs1VbWljO1ZuV7Uwssx9cSFQ6a9X53O7caHMp05muLizPNa6n9qfCpaQUrm2v52bnF+cas9Xp6UQ8vVyINSZXZw4bgVooJIZG9rVIOpaenVoea08mR6a19Pp2cEfu7Kwdri6sz0xtBKtr2aMdKVlobiQKy/uT89uHh9djrUaimiyntMmF1cPRhZkDcVQem0yI3eVQZG+50EiGVpOZbkVLRGdWtFp2fqWaaGlSLp2uTa3tpxbnptdz6qI2Gc7vHA0P18PiynJNFqf2FoLb1blgpzWz0Zw/7CwFW4XZWH21m9mdVeL5fSW/GynsSKX8wrLY2WlvL85Xp9sL+dxKYLYUXa0c5nfS3W5sv6CpG4vp5cN0YK02uxgc251LhNKja1PxUqEV2QjLe/lKVlsJ7FaXQ8M7jZK4fNQa3cjltaXg6EY+k2vs5BOrzfBuNH6wNqeI0Z3CvLqxv5uKLHU7Y8HGyGxpbSG9vntdmo2MzowpGzOVo+ngxuTCSmO4sp1W9mZbwZV4pLm0nZ1N79abiB+cry+1ansteeXoemhJjianZ4OxvdHWsrqbD5Qq+yvzYj63eiCJS1JprrS/tFQQr9dH1yLba0p+eqex3hxrt2IyIvSFTqG03N5vdkaWS0vLUrzRKSSU1GSuFk1Md5MLudhIex0d/+mjmfZ2tykG2/X1+f3lkVqwvdqWWtOVw71kJlqdUrZLuxm1PF9phOWR6bA4q4xUcxuFo5VKI7hSWQtG91uR/PrBopwvqLFMajSyhFanUyl1k3MLI9MIxODarFhbXIk3F1dnoxv7jcj67qHWibTXE+FSenEnNVua6mR3u8OFnZn9RLea22nnO6mlhcJcOHQ9uHM4V8tNibvp7s7KcnR6N6Joc8vzmYXcdDy4cRipzB1NtXLrsY1aNLC6lpvcqYUOl7rTK0dH3dT1o25kPytPKmIzGqg150eaa+up6TJivycmXENDQxWpKiBpyH1NbG+rXqEstsCUc2JGrKsSeoQb0YlCu4N+y81WRyuCaeZEWmmiF6BcVzrkyTOOZcu2hGo3OcM/P7SNP8GfTVVru1FHHmybgH6AAQJ0vOXVy+AOcI/6K2zJh6SWCVdHq/pGXdwXsNpTJ1xoqeogHRpf6ECKCEAE9gR95L7jkeG/jZd4iBPGQDmo6Fjpvzxs+xPH164pqh/9kpH8iwSqxakiEh1BDJ5ynZCiHjrVoqY05HLxoC1rkhtsOL1CRdREr9BAktpEUImD/dE19LLTBrUvWQc6uVAcrB7B4raxW5HbbvKg0gWSDmVVKypkvTy4yoGs1XTTSn9abEiVggRWiCISO9ArN2plgmsXdYwEP431C2a1aMkksTHOrU+jxcRT8s0P5iQeo0C7a5SGP7QUGTOM1k9MM910OT1gkiKrWAhvlkkRL9TyCBKCAk+Qx6nFar2j1tzmT2ghyjU0mW6Ak0yruQDqi06uGUpauap2m2U2MJi1puL2OPZeriuqZO+doiLtH+a2X//YMhvVwNY4E0g2bimgCLCDRdamWK2geUflwcrUbVo09DJTzE2D+ZHwDHmaTuWSU4VMbt1ja862QLbh6x3aKyN5X6zX+zdAZsWhAceKMEn+TrMuN3fdDVkF1YSBwGTHgJYCb0b3vljvWAgNfPRXOo2WSr4ClaqgnifCaDs0VSAA2GKd4fOw4Hq6ycge6lvrFumlm9vc8LGr06orYgVt4iDoC5WDJveoKZpYp7/l5j67y0EbHvQpdRFtw06LfsdPUB+eT2jX0JbeM8YR0rtpaeh3tOh4mFBHJesOptFkTqykkaKqdFiWWpoAWzytaDNw5YQNnI3G6Tgtc4A/A23elbpAC7DNBhBpSzk/2soNlc0Z/MHTD/Zn9A5zW9LcqBHr3qafUdtyWaP7G86PIW57aN2WRBcbVcV2avgVBccjIPjcXJv6yqNPsKUIKD8Tgh4zsrVFGfW2Cl/xZLirrtO/P3vx/J3zLz4+vfdZ7/M3Tu///fTerfMHD/7x7VvHCPoTl4dHCgo8I+WtVl2fkqIqNsDwTh+fgRZeoYMIAWAAhQcVlYpgFGNM1yaPRltADIxnXIfiFF+DodkWzJnRJswAKvhzx5J4voNGiwCVrU2MrA6t4sI/71Oaa5ltoWvX9NkwdpNemb7ZQnsSgetjI/SalozfeHpN/R3UxUD5jNFY6pt2J78m3C6F5TFtU/iH7VTwJxCLJfDVMBEgsKJUwLfCX+3U6w1RK9fcbddm0De2dRzyjp24fzH+tJ89xk88v0CUga/viJAUH588evHizbvnD746//63vZsfXbzz7vkX752+9vAf377cu/3ak+9uC7Py5D++fSEoPHn0zZNHt1Hhi9+/849vb/3PjV+aMRbtCTf1e2E76poQCoaj165FGIFlGKzsS+0iHi7DYjNJDKItpa8BoYBbws8mHFfUYa0svdUQCZPazj1VnyJNTRzb2j75vwJrkvtq9IK+Y9C4jxRU9EU6bMmItw0+RWFRJU3fvwqxbTI2MK7mRSChUjp4KpBDg8iVlVaXEk2gW1CDUSwgajy1hZrGtE2Qwqwm7sRa2k+sBN10LoJeY+RB0yKT4mhM/2F2pzLNN1xtMHpN/VCq5aZWHzL4RN40hTAZLtHltXHfmCuE5gyAcUuIHYM+4C8vfQMtFZPXDSagK0v1CoK0XAfnqylEWaaUZlMqw9y7OfcpP1iZGJ8o3DCeMnnpVqV6ldtKYLGCZpW4LfnJP276lJgprqRT173sK9i0FPOFXDKxNIhrVbDxqEY5ftyhnz547CUZXJiHgkPabbbf4XhIejhn8pYj2WjLgbPEtMIYLgDDjZkiNJDqokHl3Fa8BWHMRezmyhq+LVJrygH6lzehQ2992LkjpTeUmoZnnw+TEJfXzvsxsZEIIkS2oiIkk5zCZDyMT6A4rmoV9BH905Zbxk6iHwl+g6gAJ2IQH0IOBFf0VbeOI+ETncLigkD6KGcQintsjA/+xO8izIVw00gPdDO5N6+pH0tcJjaIbwxPjI7DYMBlxncXvkirKSpcy1mmyYSOxoqiRmxrzLNOxKaffbOwPxbQzOAxdze3azaJrU8CxjfV5eFpUwu9kTAkemXE7bEPZoDYWz8xLRd+MiGEg8FL+bIlfKcpIK7s9N43p6981Lvzh/MfXu29/S52wxOOLc2eGAcfGVUHLPNUM+es1wHumZfpGHuGh0RqYvaVHjoFTLM9XstHRozpZ37QYrPrdmBiEUYC66qzp5jRJk+Iw3brXOJlbKsxO5+SSUE86+lrL5y99auzLx6c3/+AMBHmKQEunMOiiX6kwoIsTlwsL2C4bRKGVzAwPCdVO6pE3nPtkxtmQoyFhthFsoCKmGlJbAslSTuQJOKaLJdRIU1pqXg7o4Vua6q/70aziZccdvL01L7byTGryzbX4MRDK1OWKA9AtV34jDbpY4hyxeF8hT8lqUo4fJOoR49YY10IlWHbmtEcYxDEwRp9d5Q2SCde4Rp59lCeHVrE/Dj5rrd2IKrFEgAqVQwmhuf7aHdO/TvxSvSrhVficY7VR9ueTgj4JKG9QCfCgYLCH5OWjBb1cpoABqehJzNUXrRnuoYYdwaMFH930zlDsNl4OOu+sJ2gPl9T8eFZxecpQljLecod/HULYPyCwDMWdfsD+2NBQTumLyx0H9CmLcx5RdJEua5auHPYy8LV+X18jOHpnLDJDX1ULbamvZdJgBZxD0AEiQ79w6lpKHq62hLYaMnYvKkhHrqDFHOR/Ag1PAYTr+slLO0TCYJqdohoKB3WxA5aBA5AJ1GKyZPAcOnkwDy/dNa5rWldB1xsWy6hIlSII4rhNjA71ad6X/317NVPhGNabZNMx5YQgDrj/kj1hAqOSMB88u37fEG2lNaiLz/FTUD1qSePXjr/7juuIieLW6veekrn5/TidPkNRGagE5GXa5hJSjaAerf+9OS7N7mSxqpaS1MAYDGtPbpoh7r07LIDa11fG9hUXEe1wXIVT37v/ssIxieP/3B297nTt37Ze/YeOYfN+4s5DiChAh1TFZW/QgESTt46i5KAW20ZWGLBbUbOzQJ4O2w93cw0JxVFy0vlCfi90pS1VFMsgw8Heecy1au6jPLHtOsT1akm/9Vow6ApTmTb7Fbh1cH3CkElHo1yBMlGziqi1FCavraEEWxQSXTwUGJn8tOwUTsKP5tnRxAdjiS4gEDT7Vx8gC5WbwBLK1joQRKl2MaSy3/a59eN9UXDHvX/uNi1EKqxZDrXcFN9eDXNjb9uhrZMvE4/7xeKlAgPZcwBVRTYSCYtF3mFIMcvmZiGGOoDqY3+RVsPrafaQUh96Hb5jT1Ul5puUtcj/FwIxyJwtqICzOmYtkuZAcS4ubmlMgt4ou8IZsX9i3H607d1HPTGQyfsC1at1cWSVOcuG1DL+JXRmV9t1WXNgNLDerd93vSFtjaDW37EldZbNdE9UGOna+nQzj997QshkZ9KpYTee+/17t4GSvD9S72Pf4nohXLYRZiF+Qzw3IRPj273Hn189ucHSLj5nxvP9m7fOb9///SF18+/etD7/lc2VR4Bk0moIGEXQYvDZFx8gF1FNRk7uZImksDV++HmxQePnzz6Rgj9943fQhSDmIDkjNPXHvY+f8MAEauTJgyR28PDEQIlIS6B/iVNoJknkW6ahKlgz0guGQ1eDtXFO++e/u01NGcXz9/ufQjTjKbt9HcPEJznD5598vXHF5++DD9+eOfstTcRuBCaADVsm1Lok04o9srBE6q6WRwly40Q0ZlRUL1CEaCvI1IhNYtt5YCrpl/yOH0kbVbr4jZYw/rqc1qz5YKp0qM3wU0ghLsgTAgU6aAi+s0Mag56JkQQvLWgLa9JA+PR1SqA03W5KZnIGUeNGHL859PqNbTD0H+o52c6lZbnaXXY84un88Po36cr3N/54XE3+om+o64RLJcRJ6zxM9MmXE9HZAXJZnTiqVyBL8CrclvVihCEiSmSCJ2cMCIZ0CGVOmoXDKHZBI47L6bwjEC9B4sgp7T3JVaEWCPo8w+yuCm+yYmO48CbHZ/oSwEXt169ogo1zRFb7NdkaJKMkRGen0ZoYHEYSGQLawwUNCfm6A8n5mkGza/c7BiyHmXWDazdlZuIJ2bbDo+GgWfT52EeRNPnTvX4MceiUsWVeZCb0PIWIafsJtsE+4kJKKbWNrYTN/HGXFY5GgErvMk+bRng4kFsQqegUedQycAkskREHtjryEiCxzD+xAqjsRT0hCLYZiMXqh1vnTu7xvozWXDoe1xwBVz+HUW2TSYeDemW4/S2EU+qaW1zV3CbjSGgVI1d104Iphg5WF1lmGiQY3GCiwiiF/AS7868cH7/9xe/u0mbLcOugSVTWS0+QA1X2Sm0Dp1A1ITSKNZkrEqoui7eunN67xvh2Gjajxm4E3TImF8qcDUYOiHkj9YHIyL9Lhgz7GTcmF5yXbFDCK8DMbZgM4o4a+sFDTlk2Y230Sq++aS/KW7gvcX3htGArDtbYi83b9QWpybXJQHos/3W3ACsagKSsf/0LMAHBcUBfxctCH6N7ZXcFp7+GK/ziUEW0b5rAdN2IpBDVNg8hkk62RJcHpP+3fE2RK4SWO12H0yRgDkS8Dchs0FQgmdObFYwZFLHnagPZ3kAdZ2tTRz0xhePf3d+/0MQDnH9k4A+/BMBCWi92+8jGQ3xC4hrO335+d79t3o3v3zy+HXGhPEaU2fMcGK8fwwScLpTA3C4UEMvbTPuiAmoOIcBDuthn5X+uAB2DqjnExc6AyH0HfptapDIuegtHMh1aQJJXcBbILD6LWf/JTPIk+kKgv2hm5vfvzyvOwizxnkmtA9rrHOk7Igi0atIdEyoSfe2PcrWIH5Uj3wlnL39697dz2xcczAcY4zzIPbzaig04UhhKUfZliR8GdjWpIobTm8O9ZiCi2fLocKAoVVdp3/94PTerbM/fXPxxl+BiXagJISOW3ePIWxDsEk/OirlsuSG/pgeBIduLNaUFuXA6ELhgBBefNwbogyRPKnEiVeuidDH1f/KjWNvefkHca1Y+vH49F+6IMTPi4WHHSDxCSvTWeH8q7+df/VfZArOX/6v3ttfGFIfF4iNyChPvvsBFHQwAKF3828Xb3xuzBo+AOHuAdi2hthyy6BZx9D4t9tKp6WyOytersK14AfUY/LVQOht8BJs7d37hJPxes/dBCr59696f3wJyann/wW+5E++eeXs8W9P33nPABoYRQIBVkgO6vjizV/1Xnzf1P2Dry5u3Dp96U+4LusbS8aPSYkn3751/vynvRc/6b18s3f3zwhGUr/3whvnH3xigAHIXUS8OjC81wB9EP/Vj9lHnwzek3LwlM/E+LfpwgVdW32548v/oGnBooNdIqD83Qk3e5pELhR119JiCRH9bcnFiQ1sgH6xgjY3AdNWfouA7toyT4ofIi6Jbb0eHR7XAKsBYUzqclkz6IhJ5mWkHc+0sfKGcI9wUEcL1tZAEkNWk6IhWWJ2SAPFgf11zBraDG6dOCDeBEH9iQlhwPAu3xCmrYAhMZDw65d6H77O4OlD7DaN7cssnVj/CANJ1FiVrAATW0FIVYUJZxTQaaPLtOdJJRvt29yykxBSlN0PNMR2Vxg4R/xo3Jtu2lYDSSgSFhxpG4gb93i2+I3PvmBedHMLjGw5i383XLTQxljJYdQGBpM0BPD+3NaMdRaJYVARR9U0zyQ9+K84tk030d/A30AM+i4TW0coSLp1GxOMDeXlBiIR7QmXz2Vxf0ACCi7qseEpHh3iyIi4c6w3cnKMvp64rIMGNMA2SM1tTj3CD16XIChP6IBCQ5ab3Cvim5uaJhBRSb+f5MUPeGeRoykbZV4M8+UuVDIWB1sXkxg3mMlj08/r33XO0bUeaLr4i2UiF3UDaeM+wknOIv2qiIfAakqQl6qu3t0HcBrrYU65/U2Iwj++fQ9JSUyW4AUlxo9YmWDaB1bngA6ni/+SsGKnSRzyXSd21piOH675uQb0yifY4hlryslnmELbXb1uedCWxF0HLp5jXLoCYkaEJlCxAYw9pTkUODPUDO0IM8bdcKuWWddl/mMKMNBxn/4Q2jqxr6ctqq2pRarv45V8RE9nKtUPC3jgGSIYGGDnjpzEZFgOXcFwJc8KY/ddgfV1bIHB7Cg7OS/71WXNq4p7jB13vpm88iBtK2dwDbQJB8JiIyr8LkBIRblh0xFgagGXMPDuyjwB5gbOXnmIhCGBV48RLCHKhLNv/9R7eIdU4JgUes3blzzrBdC69CXLrJDLKzgFczboNT95/yylvip1tlH0SwbInyIDjipWjiP+/Tay416ToD9MSNneJkt58cYXF2+9+o9vXzj742/AhgAJZ5EgJoKhmC+KZI5bm8cMVmeNmGGLqa8p0TTww3Sz/vF6tt3svecqVJpuVZaCw59ob3caqMFCt3XJ1r3CtoXF5vHj8uVyMGJ3EoV7N1+wnaPmM/Tl3nO3ibKNXwuT4GsWZwxeBKv1qYVS36L6/tgiV5D4waQ7Mi0Rf/XZT1XA7kqjJx73L8Z9/DPnyDHkfOtl4sItF1/GY3gLkMR8X0/bizkJ9pG4zWyWMZtQcDCf6aPcpbGK/bHMbdoyF/dugGYAlFgAgYD2D9ENEBVH7+1v0LrSvUS1+nhH8VYvdBEYT1tC+HcgV7Sa1Z+mz4V1KOp0Y90otVT7lTNbEfiIJs0dvnYtHsEyixAICKFiMBiE/ztOJFS64gwZqN579HHv/nc6Z6Vb4jKfnS9OX3soLKGW0ZQFhfMPPjn78Bui0jDNEE5dA96KDrPkyPbrn/sx9HoBNHfHJx7eVQXkeSLqgC0wvu7s4BtH7P7k4NNnu32qch0d602dFGEKUUOYgg9Zrw7sly6OF5fONw36cDb17raYWcoA7lOv5m8pLbdelQfRrk3RZw560J9sSwWhoRFpqlguASmTQzRLzreA9CbZQUZiCmp2Q2uV9Hk7THxDi69x8SyAenDAHfc/oXD6scom280uRwnRgPoK2iYFk1XQxsoCA2/5y2Inzdq4412zo0GAYbryo++Q8d9s84J6DRt84jhqRT3wqklHgY+fqliWrE4JYMYh493n28GhAUl1zjeHbk7USQuHytuuKyXMDTqZfJBB6TCAQjQ6LmxueYU4/EP0jjVRLULQdfQV46U+uzqUML0GyOMmuypQi5q+E2yCPos0Et/mlsd2mYXZTVSVlMauLy4sSYG3hP4BjFkIQmATGWKLwSIWYBoltRDuiGCPCRa+iC7j4NTEXrACId7RF6sLhSOh4SYKDhKWdMsvt9gaYrA2KaxbZh5On8NnJlgrfoQEKnWviOpcuN6sWgQ39yJuzaY3MAqR5XWqjrO8lUXV4cpUX/BNCyxbfvCsaFbc9L2JITRqRQnjrw+K9c5RC154gEJxl8mlI4GzzpUkJBdDujllX0b8p5BOFOD+ClGvsoRWSUhlUeNara10tmsIG1Sh1SnV5bIwnc6jFlAppV3x97+FBlMqw8sPjiU0AsA5RqaIkRzYjROnDcMDMJVOFgZ7AFL+mzUuypLdPY8CsLll2hHMJAt9HL8UvWAKEhS/UA009Uh49fz/hxBRZxTQfQJxTBZQ8+LrDo9H3+PYnklvRz9ksCsRfN4yGxuqprt8B9fme5/27vwaydECScHTu/OAqPl7Nz87++7XBDVAIkM/4kLv3sPeOzdsanbd1bXPUQwiquNRTHH1x5ze9itjmiKHyMjkAdtxHSCsNcvTJmkAENNaegsf4OSCVFN2pWax066rYlVyR8L2jmn2ImujlgMHN3rJacSzWbR+S93tB7ytLyj740DHqY/IjMHPIiTFGzhX7MzWS08AgsIPP/wVRWyOV8Af0fnY1opQwARNTTp0j3q8ztd2pCLxLptwzXbQag4LTvXtrLnFRpE/3YmxmDDRX1VCt4mZ5bMtKCf1OtpFckaRxNOW2kTyxmq4OZzzo9jnYoRm59ricYGvQRfHIRuZM2aQquWOqlETBoIiRotD9IgAFzaB+pkiFhaJ5Wic+D6HeYfhYSP2VRAFiN5MMl4iKiTUpW2x3GVZTckRcaVbEsu2v1y+Mll32rNumUw5WREy/zbB5urUydape6A1qMfk5vgj5JF/2gQSkwv1qtSOL3klckHGeTlx2OQLblFbQBNtsLQInvhXahEX3CKGmY4kIRRmJAFhZhHXpS4O5C4RTTU4ItW9woFUaisKEl/KEqJP3OlDiKLxGjtFcGGooWOaXtav1sRwLE57YAGzPB4/AqUiQ5Ykt2dzPBQ3e9INcXFTaDhyBiLd/uMMVhcGFj1ToF0UavSGwW+0pkOMvlJDUewlA4ImfHOBzbVSdxsD5irjKUQl+iIBRO7uGggz7jD54aipxY5MD5JxweFwIN9/RHvYFKyIBLw2HaOr44wDMT2n5o9pnmQ+vLwGzYfYf2RGk21JrMtaVz8CHdscJfk6+3fMr4HRNrfDnKeX2zDjg7YLaVN3fCTngU6nITjUeB/s3cWR5XEMKpcoiRVfQ9JqCsDjcsjuAiH2K6D08DUwyof5N+IhejPCIw+c0D5wz8cL3SIBwnDon6IEyXRaXRZLviGqkFLg2AUO6iWcewCO3ROuNXLg+1qIAPuwLyQS8VAx4rJgHr+RYseYBJ6J0N1hy3KrJkHoflsiRjwwYzEdiC31WaCAOnSNQ61BzAkv9WNhdU18stjBmkUaOJ7iSbEUj1JCVHUd24A7GT9mbZ24OIpVkcgvf5vcqbgmXCYtBb4d3jwGmE628GWwaxzfO8EbosiGX6YAQWjQ44HAMYB58h/HtCEAAA3p5KfHOAk0NRQFyCeeesqjG1c48Whk1MY1PCf3moojzOCTeJqjg10586Zxp8aOlEGqI0PPr4viFr4fK1wMjr7vpR2zrTF1SmX+uFOfoJqhi8EWCwfupL/hSHUEnA2LUAqtLTZVzJQ4ojslJA6nMc5IoWrGR0O8d0FgR9jAkE/RxRCdJCrTmTyn/vA55agEJZVdnisbqDD/SZyttgiQOnXId0aLamIbPRLtF+jmCSAkDgyfMtpuA4WZPTdl6eBQqcgssgbRyxrsvl1j+09dHHD8s57eheRDwd5taAmqLpoyafyYdP0UZjGe2tp8Sm/1qa0TF0+DcSLgYxflHeCQoYOBHBtwCYRoPGJ7WpDfz8vOA0uxVlveRx9IIZ4mA1XAzTMir5NHR/rJ8x5bfDvydhMC9mC7s0l9VsaJIR575rkkPX2lqXfIX+nF/2TbCtzPwksIXVgRUY8mwMt1XBNzhOjX5rGLJQyDOpRTpDkWT0ywsnK0GuNjzFWANaJA0Qxv3n7GrUYKuGOs2cXrzNJ4hcaPCU6RpcaLi2MvMP7JKfeg9wp2tPzq0B5c3NqcbLEjlTL5+ipY5aFNl/kW5xhfhrRhEMfGVRIxKdw6wVd/rsvgwzcauBnE2eOaWFAzX555BRIZiOrtPZgsG6X1vk94EkFg1oPSQRfOW90rsHWmQWlY3jpEwembkozvf+gTSzPHBxiATYcTx8APuSqDMv0qmxD2G2TJvcJmJJaJhNghggndXZUM4rsQMxEkAc8Ix2SmQXy68uNr12BAFBEJfamxneS81dGOq7dgs6IvEWssEcFCB3xkFX0ljhJYuUGaJN0BFKYG1CWXLR0os7TC72oDBDOcPKlhGSDrmGMkyXKtog0hR+wUxsnRp7IuB/AsgpABo0XmQVuR60PP9m5l8U23B0QbhNX90LXLYxeRrriKVnnKDA3LKX+st7B5zNMm1hx0wWQc3CwnfMEUV+vKAfq4msK5dR2Rg4lhPrJZiaggYYaFR/5hxNBGoxGSrgs2tw9AwZDZeYct79X8DWzbEY+ByYX0o+vKrWFB0oenY9PSli5jblmWHS9Jf6mGp9UGZz1IQ0q1XRzDxSlraOOUQyRUXUcWdqyRxWcyqrEuzozoJZPzYxGIV02dbOmHlH5tMHhYtJR5XJdCYGdnbDcNPCg2+cAJElIIA2Jwea7xcSybOQoN1Ayb8oGuy+aV3k2iVqMwBCxk268ZLKIsGwK5UBg8AlyGDMCGGfDNR28AfHRCaef85cBlW+fHIodx+bF1clnTdrJy7ZoxODKSrU1rsavudT66MiFW/HE7iFrx5f6J3hxojOkeBxMY4vkOUZJksa5LcmgpnWU7hha2GlwkvqsJRmYM4pxHTGikp0g2NobOFbuolpVnXvFtiAmTrzBvfXDLkau+jGemm99JgmMiNGAsHpKy7atL+xLOJ3kgtnFMLV7XdagBLHWO5fB1mpCxwBoXFWterKIiHZJp+Lqkgvhy+HXik5smMYXLS22+EVVpfBRzVxbRVCdaA80YBlMvtqSWWzRsMeQVrl2rQoAT9WTIKioQ7RP5ijUlFLeYW6GDNkhvY4tX9TJh8JpDHmfIWJsoTM15SboHl1VAcqbWZmvzgYYdTJzC72ErAApf5TihFR3TVeOLm/7X0zR+FFORwU0VPNsCv3DdOCTRhk4AEfR2rkAqaGvpRCG1mizq+01vT3+D1gHYQr1JKpWZLgepJMYunxzdaOxmEiRVOwkgR9wRzx7/unf/rSePbjx59Cm4R95ldhM4YJQ18i1ZLog3JVOLgE0G3ZatGMGtrU1faBxKsoJF/N7NHr1YaiajwRvU1p9DsnRsO0nqcFZCKy2SPIUm7sG2QXKzXO9UJJz4B4kQrRaSsypCqSugbx1EaHDwPRpByzYCg2bhuzvcrMsUB9SQkJ3uZzdteeGhHa4S31bdMa6ytSFz+neMhnwmByeZ3zLxeKxegZFNi7F61ZVK+2AfeI9ZCWbajTOygnkSDSiFZowEMgYnG6r9rboS6Wmv232M2zvxeN3pZGEtk1vwrkxnkVBGc4ybfSav4aYxIpBq3mN9vAAKKICMb0YKczNxYg6VWAhEc2syAL/EFI8z8m6APVOFs0umZSAZS2s/WiTfTXbIRuO0sqHFdjCI46yujHImgyt4b+8dm2gCI+O1OrE4uMPfu3H+8bO67VM/gyfV6MCjxysme4hIjfwUMnttU7A+cxwFEkYZIhe7XZsuLl+KX2pW6PstJxtw/O9maNwX2rIHKL/62tn80TgvTy7WoENAQn4j0lvxth6zzyuEcNg+4jjJx1Wn1ps4UQ9hX0iKnibxqtTv19ng/TWlIfnFdkt0XRqH+8mjF08fPUIrSeI6kMUkof+IIZuZOJsD+fGBQPQNwS+3x0oc8IZ2kzhe/A3eNWycjLnECfA6ZdwffiCXifinVtdjqalNGb9ChMFkmo7mFtpnZ5a+xwvr2WT+Ek8gGsshb7Bs/3PjWWAI8zFs14cjtyNGMY1ogcmR/7JghdhTm0VrxFEvwOuDvL1KyAuyTDR0oCWaoQEIvm2csOwu+IuGzQI/bfQ9HIvps4QZUaInJ8QV4lgMcUHggW1hu8uU8QyiYpIWqQE0Wi53uSa20YiESBgH+dHfoG6QjIGZSngBC2PZEpTl5GLJU3wwkMEzkBr1nv/89Pb93oefXrz2A1qr3t0/n77yx94LX/Y+f+Pss4+5QI+Aglggony76RQwGHeCpFSARM8EXRkrrS/fiQnpKF8/bnVAZkOAWSHorJuo5endc/6yrcphpUBJ78tfX9y8fXrvdu/FD3qvPQcM1Yvv9x48d/r6171v7/R+8zL6ffb+szAbD567+M1Htnj6BBQTRQ0Hw2GflW7sSt2iKh8BEQ3FuYoGzQmFR33b5QY7oiPhyx0dUaP4pKc39KV4lF6zY6MJRkGJawBL6IW9SuhcsnCn4y7P1tBAh+H+fW85mfjjjxSpAf1xDjDEweuzwAEDZT1XimB1+vmHaLFhegV+lchKCpN4EoSzb19HC4ZDFbHeTgSEwecv/tJpCQl/RK1NKZkk/3Ak1LCOAFIJgTEdQkoDsw/XymzX4QHjN/ruwx78OpYTNSe+Zya363rNy/D4/IuPe3e+0rET3PPuvnz6xpe9D/7ce+5NvHXhEeKe/ukbNF5MdNHZdPrCV+hUoqF87qKyv0HN2FDaAUA05Mtg4gm70Lvz6emrD05ffhaiYtk6QOcOibiPe/qJ3hMl7uiEuvzQfXyTumFTIenOgyePPyLjJ9FfyQns1Pe4JSwCQgBQOcquLQe2A7031Wdr5NCInqqJHcN2+qtjUh8EhMMZ/R80CscudVdu+UAF7EPkU652mUXRifNqsbtap9EB6w+jQ/+aWA74yvhx+E2cUxBNailc5hwa+wKblPJ3iKycU5itTZqTJ+GbGfdvDT+99cxmwrdBgjX7fVvD4FI77jZOeCeXWhJ3gvQxkIv+7feQHQbzzqfvfwsk4dU3cf4+HOLvDzdO3/uIocOzwGX/5mU9gA/nZ0DoCKIppy99ZtoXBpuFry4IQHo4LgYt8V3jPNz5aXOINTn4dMJDYmcUjj3gHHKIgw0YWa5L5piGT4Qit7xYG3WFNHYQbNtYs+L/85P/8+9PuT3Xhr3/d2Lct/XMvxkrvHUcPvFcu1JEabpWmNOwr1XvwdeEtpEDF9G2J48+h5Q2t74+vf8i4UMIm3325ve9F9C2/4rQe2NeTAclnaROk9iCUXxm+YJBNiqzuKn0yFtpyjBf1jyZA8dBQDh94/3Tv712/uBx787rGBwSTJHLMUOXQqU+YOTUvko+QX0VhgNFtHcmjoPe8NUCeNtxCk5GelT2nrvZu/81vwqDp9HGZhBWc1hwTbiEa4Lbp3O6HuHfBLBlFesaMKvqRMnlK7qsLAkzCjRFyh/Aevxzw7t0WUicEmODXF2a5sb7c2E0NBb+XzHyl0hWZ3/93fkXXzx5dOP0nQ9ImHk0VnL6kaFzwRTKNQmOnaIXOzyScCxkBGiwmkwSj40HAqbyoI/FP0xxjeDMpJ+tnLnRNv3Ft/5Tl2czaPIucf0Cczm07KUq0O9+27t1u/f8N2d/frN399e9B98SjgLW885vnjz+Elbavv6EjhAaobP1p3fuPvn+bQhZzyojpv/sO4vaFI5rcCNEgrGEBgLepV7+jGODbHOj/A8Ld8EqmkfHWgbPrD7kmBWx+QACb2hEHMZl7MyyvQMLkXFunhucfqyZszkEXJ4BjvWXzZgzLHQePX0nkneVcp7QK1ODb7/pPfw1Ef0pNrz5iVXJhlGZsvxFg1cDdomOz7Rr7Loci26GOO1cc2Ko2A+PrpLpK2t4hizbjyLBsW61x1i+GrNUZ/+qfHSxQbTk8UcCaQKRAsQa0ebIAzRk/AJDa6y/wSbXQu/bG70P+9Mf22bHPi4/dd7+DutI1EWITSPqIr4TKrxglgixdecPft+788vT1x4i2M5uPX96/+8GFIQzNpQzxlT2mcYTegeI55KcgjgRE0f/yPTygdaZf50rFBwNuvprhVxwnY5zS9VpxG4XKj/0owiPdWs67iC71AHQYWurof5kCmp5seu3IewSf44r7AO6WfnaTJiDquw3ae9y0Q5W+/z+h0iOM7HBRMTFK28RgO103DYBg+guZJDr85mAbOK4HTWxA3e7WYLycIraARIi0dSCLGwKoKNrJplanV4T8TbnJnmFybdECbflZS+IUQLDCKL3nLCa2F+uUKVS18vPwxlNjuybkKgTAgFQnh4L5b07HyPWpXfnIY4QAFGQidzOHc5Wuux0uUCCWRiqcsN3nvfBdwgNwKvKQT054RAE4MSU1NIYq9caDsBz+bw8efT49N43cAdA+M8//uH03bu9Fx7aHd5JUGisjrkJNwfGLHCcqj2B7+BwIeZUvCytLE20RbKcHsPcsbAW9sAf5pypRpZe00QPjv5xYl9G1DXTdehLd8nK9Qnq0G8RTVJE3zAOsMuGzFEWEGr9O8B3+dr+y7GdZgqCHKFmw28WK0jEnhqQu7E4nSgkwNaalPB3xUbdNWTSk2s1uKUEHwOHnMTHJptzbpFxvQFpzExQMhrIOvipsCBJLcM+G9QfdXCGb6OSErZ8wVoRnBoOMrQiAFp1hDcVAZxMfUoTvQKI/WY7JacpMV1BNAFWQgNZZKDDLmUzYHowWjI7CN1DipJAYt4MZM90geHh74zZrEINx2jzXtvfNg2bl4fGZmrgcf5sGFH0KWC2MDCfEjiPLJ0w8o+XBvtS2l2nfOAs5Te+LPXB3bVeHF5UXQwG75WyfAf7J/EenEgBpzQmwtnp+x9cfPpy78O/nH8BrKWuyaPnDrV7edZyX0O4/LNbL5ze+4xtrv/ADNSh1hCb4rbUtt2nlqQis6EgqGRK7Ss1WhgzCywA0TSbGQglNqFvSjhZJcSZTehuOD7ctg8u2FXcDnfNzdpA85+FPPHw2WBhcM/mNPa4ERLPyzGtt/7BDwY3brfJIjFoiT1JeQO+FsIt6An2hNuzGdqycIY8L0n9ifDoXF4nt9+41TgIxyRhQ3aiXoSKEAR4ShWwCIBDMbOVEcQykHQVv2yJMCcqnic02zj3Bjh8IS5ZJlY2fq7VRXzHir4KehApNPS62BU0Bb+GYBN1iYUhQrOi1BHFEUoSWG7hYXLxiDqVVtGwseF5YKutjUVYZvVYJB5mg8Nb3njdqaxvKjWd84b8+H+BSNjbVHwUJvR9Ol/wQRgObyzi8dgMcPqk4WR710iefGzOGjrQClRF6N/ElIFR0nFhEw/WmnnXZONpOKCRfUCMOgebzBIGTbf8bMiHYMMzNNBMFhvVkos2ywJ4+hrPE6TmrWZ1r2WbZTZnfKmvIarLLZth62SYZbExO9hIUYMoZmNl9HbCbdOrEHILveiUUKdlMLvJKgjD3DioE074zIg6TpqlV2eUHd6Sxi93PEFMoNyc4LqaTq6mVxYXoRVgD50+Xd4k4s4cKmKSR99dIexvBTEvkOYQUiejg8jfUNDJrTTlshuyEcRs5UlMYdZnS6nXwR6Xu8CxtfIzvQ/nyNl9I39baToimHDHaGSnt9BrKiey8zToD8c84wOn0TnwN8cKZ/J9LvJ14GG0ah3xcW4EhD1WsV39N4hP/gLJ6ugIRjIQnNp/f4nwyRD+6+6D3os0+9bF87fPH7zmnHGLpIwk9MB8BJmNrOUm8JOO+cOcl7Zf0HNSFskzDdQkopmeH7/ErJEDUdbcbPEinkHLwmF9gVRI4uzilct72ZVhWFcDxpxzSTqUtSJJd0/jI5SUCpdtSTewn6ornUq1Lrb5VEvUmh1O9LLmht3A7EgmsAkeybsLGxF8XVHDpgykWDk44SJ5U/kIsXooABnouSHik+7A+NwFwZMR6wD2wHAbTr7ooSSZy6kOHyfd4PGZ2V4wDzG1gY1UOMMUt6ssa12SWXqbpN/UO0c/lfa2y7Bd0qcslV2rKbLFgImHVO2UYV1cHhZf2x7V3L6haKsC2kDnP7zae/vdJ9/ZLzAor82MWQioE3zf9F0RGHEXlivIM1ZGORRkQfnZ2ly7RvrARrb9V+nEsClAvDXWmbqddjIoVjrtMh8ZCRVp13F0R/jgdBUJ4cOoDqSMymKBZQ//7TMYFZ8PgoCSX00F8wVYA4pf4OCv8HOCqHOdDyhUkNJnH93KUGWUNNEQD/FbeArFjHcgKYDJEbyJhEfio/0bZ0BVXVTVzjnW4wgmpFXq1wW/yQvM0fkwOM5NP938t2PshEjBPxH054oEDwB4EVusYV/IKpiO9wWTTDH6+0qSX2jEuSEciB9znhPVp/DIfVgzjDbMMfwwhY15uvmUgdSwc/G9DOoC2PEJggIsuTGvAX/a4pQAg8cxujqIX8MzwB4Q898i8ZPdpFlKwYBR2HQxTEGYvDkeMbH4pG9DmoUtHx61hbk1d45NnMLBoKtv3kyiPHCdfX6r9/1Nemy+8nv92ISrTt206re3e9+8ev7lTXTA/uPbF2ALIAj+8e0t11D/hkmTRhtf/ZU0g45h0icRqs+/+6x359dwlfI2Er+fpxZWV+ix38yESUBZY+qNWyyY4CCak5Px/nBXXSZACOUjd0LHXKMnAwEZ2D5oFf7yS6JkYGM7trZwYhorOTf1/CZ9zlLbsXbtGimE75uAthlR1BogXLSxPq2KjivNTdHTI1wTQmiOPCecYunqfIMZBchIySq6+iq6F6Qu/aUHuvcKCUQn5FJHY88ZJByDY3zSqgs34xxneKFHxNe13iwOE9Y4Soci4iQMbhidC4iG0pbRYQaen6WuJonttsji1xPuHSwwoADw5lCH1/C26d0ZbRQtaHnfja1PfUY9j93OuO14RUX5Z/128vTOB6e3Xjq9c7d36zZJiMgRH2jaD56SaEmhQdMpCiNRSe8s2ge+KCw2pW1Fk3HwdKI2JKaAXl61oSetwLHQwBTdqnlgQi61Iw6y+PbY+xXHfLCfqpfIJoPvkDz8BQPWUokHthihtPfFvMvqNkV7wdFB1Drrnt2YUdWd2+M/aItowxNlGOrBy2KkwM0O5l8sUA5K2chfwzYhxgntBbVr0ZThmeGgRMMDGOyUXB8ju72+faf32nP2eDJQ268ixEBii5ugwmYMsc1euqRbDmliqKs8DLmOXdLwKahvHGjSK4QdM7izaOToCIphl0/WAiXE7qAXQuWFY/0ETIq0LoaclBFGjOjpq1/2Xniob23BtDH08wXozvuPeg++pllxf/MyvSDDNyJnf3nce/clYGOdgMfeWBzuD4TQooC3ZbJnM0e8N8AS2/QOn1RsV00IwUumw6xthBlhw3/pN2eP3yGXQ+QSm+im+amg19fMteD0nY9Ov7kL/l9nb37Xu3u7d/u1fjNiAtkZQisiEiCcAxvZdLt0qyMJaMvqrWIWjXQyw2vRPM57zozyrqcPgyEIF0mRH0gxvoXHSSMxV2j6phvE4O92A2rLDDnsC2yIj7tF/3fiwq68uGQuz3//Z7LKJvRm5vW66WrvzouDVpYd5Ijm5fOLU1JbWwUzb9qp1fSRQsZHa/JieioQc3f7bUk/GzjePB7Ben7/T0YZfMFCCljhpOefLf2UyKi3i/IWODS8imM0N8sSSUjFWBTMMFDrF53pOv/hXWzY8/np65/D5GHK8eTR7bPPPjYxXkYIxG3Mux3jXyfHBIITekeEF8NyR0RJz+D1sJMRXoglR7TpeogYB3FHLwQv8hIbfY9x6lJ7Y5qxoO8xz9M5Yh7LJWvZ1s2/3PgM9VqPGa+ZQNuZMgwDC8EtVGRxu4nOTbmMdzXcgSgauFTBPYAAW1UV8J2syEjidluS4G7XT9tIS3BDAiUFdGJXAHI0bmz/CgGj0SCgLrSGG29JbVHDGYdoSglMx0hjYh27ZGpYJoX5Kg6YK+ogYpkvbs7hQt/coF3xR45/R8EA8ckfUXTBeHj65v2LG2/Rsw3hypNHr+jbhd1TAsb17r6CqMHF87dPX39I37/xJSTNgi16ceMWybM5dElvZ4/vnP/wPL+juYMVAvpDc6ghSz+63yUcvC9+QmwQIOca139X799hhkBxZQoEZwUU7TaMQScCMW04++Pt008+QMcaYQIEgxBBVrDvniPAIyYBTR4aEU8o9emz+ukM2dCV34CdSstRh0RRneY9s+nsfzSvO0gPH8HsLQ184hWedmTujCvbQXlHpmdziSV6p1sXu/Z0WKgH85kZowdY2G4paxaiCHDcsRfDtQYqH4YGcgXwQmcHcKRkUB7qXoSWL5cP5V99/F8+Bf1O/n5T0HcFItCQPgQXbhaJ6XGP9Tq+pTRVycyn64BFHcAnFUDfZFq3IOkBLKRYEVSCHQYhaOvqo7rEQ98RVBN0EWwtE6J+znGPddQIk5k9LNiSg/1akayl8/pARFR529n0282FXOg01ZZURtTJFLQBZ1NSlFZJLO/+iFnAYPqxrRLe1u6YwzD8lCZYCIIxRMvYfypkmhK2TYAsRjS9BT5c0aBB74MabKCTV9QE41LlKdVqc+C3XHOKTVVnsMx2FmRaLUIf6hWblPAV6W7CiwHGGa4g6JSC9G/6x+Vh6DxC4QVcRyAzFGR7CKO+GUgcwFOgOBvkK+Cg8IToyU1JKyIWoInmk1g24C5Vrd0pg99Iedft+skcmuFYxOO4Ws2Km/Y0TIbpcc7rTcpjXU80OBbvk5ybd9jWm+VmjcTEAPpDynuEn+vqTPJmMxTeEv5dCB6OBvuiHtHpuW33yD6BJoan+r2hQfe0uqkij8+WoBBofbWisusmKkbVFBLWKfI1KUYGiVOKc+UFyif2/wPTojfxcyY7A5kkqdLkFrGq4xvlc8axuoZJIZF5iGWKgz8cJ07oSaQdFI8uEwvhcvl3FLmJva7s3lab4/EoDpADbxEhEevNToMk9WblXILf99833nzq//2KywRsmXgGuj4fLMMUXJ/JxFoZDkd/p9UClyoSP5hokI2ZsIhMWH0+PkG/Wi7kyNjtKwRL4Ow3CN6Z2H6vIpEVNwEEdxPXr7voRSZOp3pMOqYL6QjxCe8Cp4+WOLfxDmIVnOqEfcf5N/krGjwmVCJ5PVUoTmVW0oVcKpnHIybggucAIIVpvEZ4fceZJJ/HJyx45TCbJJuJx+Px0OnhjMaybcikg6UXhMeIRssakoewubR8hI4huBv2C2tIBhHgCgDxcQqJ0gwW2FBNRpikNNC2Z+P0m6JIoXlDs22dMeKLpBHM2YQ+BowTfx48TrjARsOzBWkgfTjkR4QmmVmtU7ubpM2tPpg8mHKAMNt3FQjFvXQoXgq7LV8eBz5Bp1RBxyVYq7KoSlWlXnGTJrqO6lJLSdgdbPWMtwM1gwyph3FbQ85feTqF5xqRxjbGB48NOXR1yVsQ+g0HhnPpSUfBlMt0BfUvvVCPDrpWt1yqc7fs1/731+wR+zX74Ft281W1Y09XuL6Oey670nTOGt3vKpC/qjad8m56zHuFH337xt385fWf1qu4AUyDTsJM8NLQ8bQJ3YSGWat45ZaX4q6XNyLx4m05ZLoXdcBK3YBFt3cAN0K5dVBT0NkbOMZch/DUUye/qIvN7Ymjmm8q/e8EiIljGlvTYovCSA8jKYSXQQ0xCz6dPBkMCWKGyG4yOeVrAO1+S+UOc86ZSh+W87zhI8phxKlsKj2TKQIl6ldkajGzMj2zmMglSbEhE4kc7+tlqoO5SUpuOaV15sfjoA5k0c75Ug4h3f4pz5wrpFu9gjWnLSpanzSpVwhVZEr6e1U22wUOOi9/c3rv07P3PnKZs7zgAING1FIcH2zcgbT2TVRLvNGi0cjVk9Ne5tHEFhZcBUw2W3zOHi5HLeYg2Lfxy3PTeox4iENWvrNfRtoTy7Q1K9JhEazy3IhIO84Ypzf5pwy8ftTR8y84fSB8XPxKp8+PPoCo3YPZDw/Pju6Jx6lmrMcUR+eskQehXbPAAa+82JyT0sfjk8sPqyudQ4bXmQkTmpJ2oLR3sa+gHurQZO5hRxnj3AC640fimORH7QSgQoA26IMG8Rs/1PkFqFWA7ZnQs4O5aIYRKGMOPug8H84bjLtnNuEv8QCyZXpOE+hwuxCWFwrxBgqi2sRyFzgNo9+Et0Y/YK+SOlDCtWVeFYNb4JdF5xwuB53lpoLGmfeSh/OIxKHiyIgwVri5BpgkjBcInYn6wsrbtZLSVt0S5hVYqzQ7FTprdvvODquCsyCS2Dz8xQ7vAbxJ3KtRcVAiVaQ6wpkqjn8Ev0Az6gthmwpfGJs3+BChRf/5oqAvJedcUxLbpS5uy5Hy0bgupoiKOghDNsEBAMLD8zPcZmgt/Iw28DOuUKmNdjSQSL2Y7opNZ1zEGdThp5/8gygfaiIcNZ/O3IjDsTgYcqC/fLEQGjT6y3LQsmA29tkbchgO7f2S8dBS9gHZz2Ey5cz9adC0ewz/u0INVMdZRaknD6VyR1PabkSEiwCS1FapxVELfR632EGrLPQ3fPQ3xJa7LjZKFTRZrfGB5IWEiJW0CuRfVSpi0y8rwKKegPKFjIECiHMiGG5gVaKlB/NymWUp52RsmnMVzn6VON+BtTbxUMXx5D1e00tm2KSaIy1wdIq2CKMk4jPiKPCmhff4BVcY90sLj9sC1eMAADTdouroTWFpyqqDu7KTBB4SQwJruD3MSg10mBjE6DkyfJTKYVQAko4V4RB0EstoSOLeHA8Ft0x3jabUVHS0uiLVyrBwPvmD2JUrMCnwUqur+yF/pB/HQkrghKZgee6nnAo0ENbtxa/AzsQHdGDlccLxcChKVQH0noIE+sbJOiFNyDjeHbhApdNo+Wpox0ptarPetx8EXYsAGKhI+wGww7NZuHPW7NSSzdmanZm6P90c0CFZHWOjkwEEXFeybB/pI7//GDZIP3nJBKnYrr0hwVHHUQRm2U5Vzs4m7iwOvEXlG3b/Yvxpf9DzCyFMYiuGTwQSZXH4aT/51+PS++zvpc1CtuB2+4/DiFenIrpIowbKDc9/0pA1OMPu+NPqNQQWaPQCNa1Rf0aE6P5E6Awcwpunhw8bdc/TJQQZnRnPwD7t/aH2y1VfW+w+c+gTG0c+9CBX4PcR5ORFRxT6XUWnU73ro3dz5Hu50vSMP+NgHNd2/SfNFkigL+uXds+IuyKiVduAPM+UOs1mFxq5IvDMnAKbeePJ3QxtMV6qio4jM+1R3VzidtUcexNUMDxP5CybWmR0S2xNUxuDPPMhjAU1GfvrB6f3bul23PtRISGc33/Y++41CGSCbb5P33908enLF798fPbnN1EpU1AmrEWxiDX/fDgTk2qNhjXho6dbE9VaRnwyZIlJQu6v+sZEIcDzV1mDA6BQLoEwUKqd19Q5Xz17gJ33vWQIWxw20Ahwm4OELFvqXsQqSBW3pVV0Jka3+KaphIIFAH+nCbToGpYbmKgCtMwAD4ea8/C+cardCotxT31FiIbctAHm5XrYDG7h3cOHssOzTI9s05gZg0OBoSGPfmILeTTkmPLTPmMDVEHYa4jo4zhUpDYbCNu2hlgAMXLUGGHhjMkxjYCLz8e7oUhFJlBBzEkORLryJAMR/W28Vm0+D1xbxo2wse70LDDe+DHaq9RkahC6Yc1RXw8c/X0dLUGz3CXmlH0YMD0BhqUhd5AqTdkQiHGKlzXqFSzYABcstD/qgYn1xZxi+H8nfBBZm2AJKNw4xZsuiuB1N4K8qYgHjZPYNLikAZbuIoINJi0TQw+Ha4ipQUOrmZI4tNognVURx7C6mMznWXo3YRW3IAjEQl3Ip1OCcGzPQHmix/qHZlyEmBOTP2JYjGNuIN4PkfbenQfn3/8WXNVuvHlx4xY5J3pffwmBrv70DcSXfeG5i7fAGeDJ1++hwhCO+eZnvW9vnH3x+963nP838ekx+8NSRxC4i+i9/e75dx+f3r2H6hGAsLExHju7JcNFnvzwztlrb5IREg8y15BdBkbMJ5ofHmYhAGalikC6QE9BgQz24vHvzu9/CMfZL7/+x7cvHFOgwDEMcZYeU1xYbl+RvpiGFMPpuBf6Z8U1ZH08yAliXcz3Q8eDpsdq3+a00WySGSPCeAvoCWJoAFjDU48kWCeT7CBJAUpbRDkvC5lLHCs9HruRF+6a2dkQYUz4uRAKXiXWJ8TB/QxxIjd6H75FzNZRRQFuSLn1tEcWoOh8+vkfevc+oZHBcQXEp8DyvvUrxrA8CyatSMBCv8DhMBDW41HmhYuPX7/44O//feNj9B9IFPUO2nyGzTb7g/k7PLuXcXZckNV/UuVqs8vnaQAZKARfuP/y6Qt30YZHRXG2JrTfJtSu6icxOOymm7oUTdeMDsnqINfc7UducbIlXIePBswMu5jrQO/uy4SXDISjeE9Dk5weGxdI5NMux+H1vvorWDgLRJ4T9CsPLJsK4M9JekKfgGgdM+pPrK/G/cHqidBQXR6n3XOM1TBG8hLs9s6f6ydDVtzCDPLpre/BOerxB+df/u30nQ9IvGJCQPpRTBII0E67+BhxxNCLRV+jNvGcnZU5EORVQkYOOW6Lv79EXCho8oi8gN5c3HjvyaNXcJqq+289+e72xY23ehAA8pPT1x6e/fE3ONw2oBfAa98U/zID7Ss7I0as14zlVrGB5ewfY5bHIxo6NfVwfwJaXjJHBKuI25twTHrhEKrvhSOZ88vbBFe7F+72XnwPvLUf//Hs8ec0EBoJlIr9ek2xd+mE4CBKW865IYDNqiMRZsLJvcUS0woX5FgSZxqD9hkte+K8k0znkD54kxuL7iwA8YX/+NLZ4zvUL/3+Dxdv3KfEl6An2kp98IwaSOlaWYxOg8O9AfEc5FzApABymYS17ZbLe6/AXfh7BevVvsUdljqCM7+gK4fJGHI0puof2IZbG9ICosFAH4krh2WZnOP70Olk+lryaFfQMiMCIOYQ342YXjob/FxilxkKB3nDTDwGSJrp7qMXNkdsMeKzcEFbaBgXHLGln9+g1cbUYoAJwWGIytvIlmdryjNwBYgxylNkJZ7CC8HeyS3zc0OFZ0Ss0GHFZhYMZHr3HqIDhNgkPMUvIAQma6g6LvV1lumfEpLXr/UPZGeMB0zdSYwKBCTpHhM9nCSHQGOVriyzY2pE9ycmjlBob599cB/x3IZvIsknhGrQgLk3/3bxxue4hd7dV3iHKFtaOYrD47ZYfYNpJEenGJW684AQKuLk9OTRh4jh1OlR753n9fA81Cv68W9P373HB6/kM42R050wnhdv3u298CXiNUkIjrMXvzy98SwwnFZXxUHh+CmwPJnUHUJNsTNp6NlnWU6ZZ4lDsiWaJuWB9aCaCOoB4FipvIEpOs9Ms3A9/vL8B8RJfI5YCMQ5IOxpSBVZbBLlG0Z9R2txxqeB/MVboJ8EIgI7H2+5TLk5jjl7dIcmT7C44XAi07lDyMgZXZJMjsC5/dd3p797cP7d/dPbvydnMMFIwsESFgmSCpEcvo9uI97VmCqpTmHTDeh/xjty6yA8eXyTijgYFp0BOH3rlxBZDetZey98CC6zv3vQu/sxAceE+rz5PZNBf4zHgHkVL37/q9N77wECHHNFTwTdx4+4/IFzIg7Xfv7833DqhQ9hDAz6J49ePX1wR39D9sr5D2+ioZoSZcpX9W0w9FU2qobW206HuKH9SFv3y+22DdvwfsaCFlNf23mu17r0HNZLei43E2SY5mAP6hQZlwSc6rSJHTZo1HBs6IlUOl9ILC5C3OEF5p7RwM5e1XJTq3NaMxx8EuqA4sAFWi5LLGngt+qmKBo2vQRu01/F3dexHz95A70jnkp4hn9OT9oE6EmohPpMZRzuih2yzWCvVrTXhTkS2/X8h7fPPnmJCkRvf6EfLsST9eyT2+TQYeELLaHa9QCGuvauvS+XpaKsFrF7tB6ZmzkKwRWICpnIG2WN5KlVfaQkuRLd68gSXIdC9vfUVLJI4jVf4doy5rFahumBd7CwowuTONSoyfLVDhStcwkcehRo6lc3OC5nKMap/q4UcRO8t9si5G8vgkt0EXJ7iW4cKpy+dxdyiZmZ1FQf1bNZh9aSK1hJITeL6KebH5lZEpIriB2tyNs4Thg2z5FJ9kKr4o3IriRTAdzxl5X6ONGaEbmjCPaXbvbJ42GRy/Ej4WORFAkTjinZianxWrfYB2KWl95DlGuAPHp2e7qwhNVDlWxecXUaPZeKRmjnMAUVHY2XehOgyl4KBAEce9sYqe2LTYRoVLvl8ThakuCgtrr9dF/J0rJqgFxDjsFKKZ45JGl7/jaEG737CokEcfb2r3t3P4OAK39/9uL5O5C/jYQkffiXs8ef8moWuKHuDtaz0LT22MJtX1Y6JFITI7r8VS0LIWSlqp5xc1p5U1x9QCzW8qXEC3MahD71vvrr+e//rJMzQsae/HD/9NWv9ZiriJghXvDs3ku9r78kcQPMrBxeOz36vmYOhsp4Z2qgBr84UJGAaXFmuqoKiltpMvsEHWnsY4aL5J/BC8LWwGOsjXldnVpmJYv0ma0E98V4dQ2IrdjcRj1jU6sJsIpkcS9MtzBlNEtYK06vvKlfkymjAe0R8dqoZdYJZQ6ulPlBaSOi1BTrhOKgGuOCkc2B+AlTIsLIAe26SK69qfqf5LsjSmo6PGFiwN0Ev+7FS64wWmC8o5KAiNAfdkM1zSFm2My96+IoX5nLJcKGvYkYk0IS8pviH6ZxszZMfZmTSztTSsxY6rFMIH8VKxEmeaxMwJuR3oCM0WR0nKRnUrMAo+WVCVqAx/pdz+XhYNI9cE3ZhUylaCni5rbdP5vjgLTkw9ubZjjQA4uPD5liUVVYjgMj8njfFACmqPWkttfYRIOio7PCOqzUahgzUf8fc2/eHUeR5gv/r0+RZM85rjJVJck2blq3NTPCFljTxvZryd0zV65bpySlpBqXqkQtNurqOscGbMvgDRqzGNPGNIsH8AJNgzfwOfejzKhK0l98hTeeJSIjIiOzSoaZ950FqzIjY48nnvX3oOtChAUj7wy4rrT9norZmq7rDU6A+dw8DzEQdCBkVIJy2XbTwfrsN1aNCsSY1en6Dk3xYFkm0scVOVto1HfvfNEJ+01fw3IONCUJmrgZQqo6vSOP7aQixBWLRZ+K8pbPbb05U5+tlZbxPoXBYhhpPaV9orW3M29cNvNiJ54QPA+h4DKeHvHD4ZOQTSSLBGwwIc7hljCtd2R8i5KWGMLl3sBcARyNJUyDQUcjsqOd4hL4s7jpQCJ7ZRw3i/BkYmrMeHOCjRF73mHxTB4zybFiX6GmlWa/EcipjK/V6CXJlYokJH0XXVJ+YpZqVioSWDheJGIvSTx1SIfprEWBS7RTFx29Y98ZbK1S5+JM07aW36RsFsVxFjFarr6odin/67TH8Lgjlmfd4Kys0L8LVmaqxdrcBDj+1JrLjSRjNIEt52bLJchaCOq/cawbeLI+Iv8QkQyZh4y6SdFzSt6qOdDj1ePisEF3pL5KgvwPwUtyzQom/l0q1SEVTKF6zLGbeudBiOxVexRJmzX0xNX3bOwQNVKPkGhPJhC7Tou5+/uh/KjTxBhA7FRCExGNQr1RXd6iOsGaCPtIuVt3Hign6++MLnUfil/iBMRIdA/eBq8jkugYJ/H8xtkvOq/f7J76uPPJhbX715U7h25f4AxKoLTffO+b9VNfdj5+n4wJcWqqLXRAyJbUeufidc3UEkmorXaQyoSpwyZSqkk7L+WAlu6Yw1BMZ0jwovGnycUjTwxjuTgTgC+xSrAz9W+HxienDdNO3mHTApxGbRlkNWw4YZB0320lwtywdAPM+y38tK2Q+Qz8mfA1B0q0qLZtQJK35dt+BEsGSkvRlqXZEAeHM9vZBE1GK4NN8OGbndtXaZ06lyHNJKk91h5e1FwM1j/4duPxX+yeHji4dxzzE01Oc8v5tvefZ97yWnGLGe3/CnKr1aVl6cfqcudTOE3S/65Fn7S96ZXBA3nNmc7IQm6AN5FbGpp0RZsxCPLGvWp9inCZ+J9qzNeWipCsMuKUkdeOt4K5kCu6yigkm4vV0mzAM0HuyiUwW7DPoAGzAEx4c2kGTLRgYc7QXkyTOq25BKCZQUrVMKxt2qViDRx//Z8erZKvEBi/MPtwsAIbVbpNkvuU7zDotKhlMDvTPm1Bne0EV0zbdVIunejDEIPzg0Ok2x9ya36Kxgc+XnM8Iue3/M4E7zCxkIazv8n77JRI0j1MBP/87Sgadnim3VpjfjmtfZb1hvO6W1u4T0ittnHpWufClbV7r0Pq+St3O7fede4YAnYzz07UI+pEsQb8Wj03C0MqyJ82G6SK1UugYBViPdibfHT5EON/IWgcKtbrf6BSTsZQ0EjwF5D90Z2YzK+TAkbYge3h6vqXd8hauXn18sa7l+gAsSoS7Ybe5OQ+jwv++cLaD9d6XCq0+yDtsuHp7BPqqZHrXUc9RpBhyhUOzgVo+e6+d4fKS0O41ILyhUNN+Vb+eLCBggMCuQzb213BH2qfUvWRomH2Z5kFvl4pZRhXOMxCktGokZFeXE8yRDWI72w65DMyrJqR82fFLQGpGDRTP4SrMGQN/NdU7E9OFvZMHNo3fnhSCNHhDwOJA6GTsAdOljseol1DGbXPgz+5WJyrnkC/DE+BpXvPFevB7l3wYPMtgI+mfcWe2ANRDt2Rkd3pNtH96Gzn7Bl2SBP1rv34RuezV7yd/5o9MuEBDC935OyD9S8RXPf2uc7pmxu3fxR80Nq9B4IBrgSiF3T4Lbhfzemlc+kLcA5Ry/HeRXB0+exU9+tXbKBfr/vudwjdK1oDT1bynl97+KnYtzYuseXYRHvIuJp99tu3Gvnp0fVEpxJXTVrvwfeADhn7eUiPiFXDn1HGDEB758wmORcDUGS1TshlWUa1Ssk+VjqAMGwEdNI3YM/fv0m+LuA5+cG3QAAwPqCH234EG1rR9U+ZjMhhiW0BXhq3/86tvnex+85ZmgHy3QRCZ+aqp0XcePUHXEcs/+gjQRXNNZQ07bNXun+5JrNOn3PAl3cvrnY/fDXaDOQZv/L++n88MOuVJMd13HhIEsdeO1rnVW36Met1fNnZCLuTVBl6jMl+6fyKTPKsO2++vIKkP+PpCd3l16MhRZUdGw2dKIlAjTKtTdJhig0wiiDjYtONiv83XCdUb6ooz9Wl06zNzZcqx/iu4ntKsk+RiVr/5r2Nb78FYe7Kt7R5Nv/8o9hmatLUpalv4pDh8kx3N467oL2dkLPamGNCMJMm4MoxZnEsVy6wLt4501n90ksSDNIOmYtm3e1KqN9E5EYMYhJ9AYJSjGMzsvJIKTKKsreVRkSWFbJePrRVMtyCSlgR8bwyjrZ2kMXBouQP+kkPz9bW9ob5dsQ9vKeidJD7iF6T55nOdC5fVL6EZNcGPyu6u/6fIxN7/uvkqc1Xb3ZWzwAJWYUU2Rt3bm1e/xv6sn3R/fuljc9X1394c/PG3yH4gMj02ARcPeDteHo17jLz0W3rC/F688Z98HL74evOny94+6SR7KdHl6ZE83hzopPm6U/FvUn006Z1OGzwdcgnXTVwUYZeoB55SoJLHF5CLPHe/6779zc27lwJ7xg9g3uCT6tP4jN7CnCn9Wnt3D2jEn+gyuVTKV5fgJi2c483fvgBvfbJo5M+CkcqA+nQjY7Cp5VfoSeGQF+B3uUaeB5CD9AjbvOzd8BfDgeF/qHg50dfwoLduyBmRfRbrJdOHKwFY+ZY7BXDLU9zLVy79zZ5q26Km+neyY2z33bPwbhoWjX/RTa5h3exc0QglgoyDzT+/NrD06L50PMV/XqBAf3gAUx4+En0Uta8GBN8xbQ+hXBx8mHEMywOQMThPkIjI++KGw8Fk6eHvbPH525PutNG9WsSw870VgCzmEuwWRIiv+GAJd2XKT6rVAGY4kZjxSDqkU4L/hPSPoRCFSRWOfdniKggh1TKu3T7hvivtqwKrljKAZpGCB7kezv75G1sgVIypgD09PSq6CyJyd4wKpyeyXl0rjZef2X9lfvUUTEG2ohy+6Jvy2en6MyCeIeFkyNJI/tmtlmriX5KT5fQ+cZi/ozVcziaAMQxVeWMjDlaic780TACV7tJnRrAdhQeH0s4rHlG2iKMq/v+G1LU+tZ1HN6AzHGBGy87OK7C1aHzmJHkkub1TfcihN0Z7behFBBRr7WNFm+b2Yltgg5v4/a3kTv/trafjsnkHM9IuHvVH1NhtRMlNu7KdcoAUxX6RMdULLdKr4o3bn+8+d5p2s2oXWjF2bmj7k6h5tbqA8WO05aIqAeUsgp0AJHepXzpuIaOqLRFZGjgKbqVINIbzyEdSzq9fjrjqAx8uTF7HDnY4wFgMQGjArxBL5zUQY/CXdxV1QIYLlTWWT0rrkT9+oY9/MkFCD+/CPnpqAWMDnDVRG4pUNPG53/dfP8TpUdnY4cWnkfoy1Yt+WhclprwWAMkXQ3xH2JGHjX10e95rWMUPrQSxM0pdpYXRlNJSxLj2rGygUQTaiREWKmnCfk9RhnFiYtC1ZMPIgesAIlCuhAEqGgpf6lYaRbRYqinOGIOGJV6fjrvHAf25MkGIb+GtcAOxqaON673UbcQONC/IZn0IHGzF82f6BOsW8o0hEkzeTo25g3b6Wkjj52fHoPXFLVxyR1jLrLEVrVbNzEa2ukgobXdD0lmQqXnsepcvC6v8wuCd6EzFlXA9RyGdlOR5IJy3H8L/ed1WlomIyq115PtEBIURxhTfr5HV9ev3+pehdxjyoAY8QCIWdDQMEISpdjFgt1j87J5fai4c8cgnJOJbZuEE6+ZaC8I6hs36ZPtHGNT0I6AjsKOUnUzO2XuG/dw9M/IwsU/nhrtsTuT/dM1FpX5Us0xXTaSTuRErH0Iln8MggFFd+8tqdoItyRZfDqr34tKqPKft8R8/bu2GntzhDck//VEd6joLqhXNOYivECT782K1yJdm92j9siTUAo/4TC6p1I78t2378MQVu96Tks/LM7t/zDe2Z3Ot70Ydgg0LX0EkvclRoXKyUxSPt+fPSMGpwc6o3unxU+xy9cef9i59R6q9ZErRdYiMsJSkteD27fwZ5xYReBj7xDV8S0LkxZxvnazc/vj7ur3YLDUjiqYKvD4K4Kw/vndWJqGiJA08MS7lbk3FAIwcPryxo3zcMPePQMX6703ul/dgPCd12+CMhIdkqwI6CdzzuqBlYM26K1g5XA3Ii6SThvS0Qp451x6p/vdqu4L0Pctz3eT7kUiYyro32pNorfXm/MERu5nGXIBgk/IvRL+gECz2IwRGT3wAztE1fmUoQYqMP2xW8eClZHQ6SnbovJtvB25KwQfhe5WjNrAHi/Ql5D4SMZVJZmSNBUd23VABKo3bWEKKsKGtM9J8bIWrgJSMsr40PnxNN3e29qGlxRWLWGC0VqiTYuRtUxNvGGJMVR6VEKNQAFuwdWGWFuJ+KcYP05D9/7R2/WsROgDp8bEfGaFrG9AbkTmz+HIIfjSRydBmfv2ze47Z9GH5ZR0ZjlF+G7wB2jfTolD21l9a/3BY0gs/fgvogwmcT5POF3QU1AQ4NOI7YT6whOsRF9jktluYoIcATGm5zmtrNvvnbEe9f2cV8YvR0t6jVr8PkbSc4kVXckZahTjTk/E/MWZ4h//AAornGtBcmQ9sDeBNKKTgaEck+aqS3dA24u3Me3eyxepLrlWr5AtSAjMXrV6DG56ScPFldl978f1Tx4AU6fsNtn1Hy92Pvih++0H3Q/PrV//Liu+ctum0dBAllxYbvKMg82LNt4vqG6ta+B2w4w+aySoK7qaQpXU2nPpcmOdx/teYbZekDskdcRYhGllps6DWSJ6083UguKx5FQ0zosmnEJMjR65VugA6A7L5p7cUlQpJlKNjR5Mh8FlvWwhrKzHO9EQDm6f2/jraVjxMxdom+o8As3lFqJL1S0Jzs5ip9w/F61Oq2sL560vimL4M8m64yvHC6mPpEv6qcHjzkT1+28EIexcXu2eOykEDpq+KFtlqQrlFdJfs85ET5CkKzbtlfq8gPDkLjY9zlzSKzYrjptJR2I642M5+43HonjAfijGE0QkuWJtqEF3+EB8HE26R1AWzkL/ESR4cDXOVCYvo4SOxB2hOa+nNU8idGI2apYeZOoXw2JiZSvT7zaduNIJhtvmxzeQqcbvXFeaPBsk0lB0Q1Qy6Vy8rusRonyZVBcYrJlKbGeAk+qsGZcQsyPLjnrT/pCfj3BkKZMBbjQBzyBkNtMMwQgKhboEJief6/SIp1KYSv/vcC2k3zdWDF7fig8GmGfslQSTlrXPy+7CQ+p3ElM3r7myD//nyT+3QgDWNjhsdB5c6lz6Hog64R/hT4Xmu3n17c6jk6GXybC3w9vp7YowdDQhJlAsd3ga+5h39luupSharYcnk/amSa8xEj94uVRvhKEStQCyrgaVOdTzTRz6/e7CwQP7/60ACzNpJckz6FRp+fhuaQ49PL7n4Isvjh/YO76XPrQ5TSFPwr3JqijVYpRt114m1THbrItT7xt3t1YOkUHq8bGctNnJA8J1BCJVOTOuy1r6iVAS9zMAl+LtT0Z5gn3SbYC0b/pELcMrX1XJ3kmAowpXI3vaPLpK+oDO/e/ADffiXXAeiFEmGrEV5NLgCq6ISp1mnIWmOy6W4Fpq+Y1a9d+LFX8Egy/A4edpdNbtnH7UuX2/88lZcVDA1ghOaRDLzQUpeou95wjrFt1HsGiCM6K/UFue5TokhvfT3sLhQ3u8F5oV+LqNm5mG6PuJGISRkA8alq0ViuO4E3P79NqDzHAz7q22QcTAGCb8k6tirSOEBegQyhqkNmE/oVijVvJOTgo6Sebut8bh9+LyrX4QrQwvBb4Mwt2prmOQ2nl0mo8UkUCnIBpAri8HNE8Y/xYsFGdXCibhhM/2j78wtocpJwS7tHxKyvEyuiW2Y5hlR3XAJvNX8uZivpQSX+Wdfjm54txcij9LuwhjvY74DAkf1+vuL7HSXh/bLT/JUnGF6YFeXd9y5RwB4mmltCk3LmL9DpJ3K6APyKt1vrhUKpcCxUSr/TXiSCzrujNRDIJ8BPLD3Fxpfj4QI5+FTLjGFZyobCJ/ugtXuh+tbr56c/2Hb5R3CqC7TwI59dj1bnjYMxMbAEkk7/LO5fOgMdY8F/VRQ5xztSaxPVIhfJOuVKqW5SFQ8cVm8bRKShjElORjJs6NqEznMPEbe+UpP2KzvmKihrHfOzfNgGHen8RVhhw5DAYCaGWR/qDEsAw6zuslOWMF9i4DutlRzpe3XCzVRrwU/DM9jDgaNfoBuT3ShnIN6ixgWgsUyWsIQpvOaQmssr4V0LmSAiLJwNu/HSWMzt/KHIXoLMkvdQRPmKlp2ft8L+3FvE+2K2JRwLVWTXGuubwMmte2eCT62vYYQOvCR7R5Ns++3n37RwrgAiCxMwryz4CUsu46eRAQBh8lXgVVhTRY+60An/pW68gtGKdDCWm/G5tGk7a57QSRXqPtAHZjjALWRlWhv5UPeyqVUDKEWDrUv7M5rj8EMxdwGeEt8HGUpJfTFSnaxAlOwZ6AvL5RVqNb5i0bYrZEqGZIQaj9qKqrtX17WMg3VkVwdtN93iVUe964d2kg5jyLXSlYDCRL0ar3jj8/fviwFGui1VP8BDySIiZNTX4g4rlArcSqYPlq9zRwOPksN1tdXnF4RPHtCObS2gIykbkDIJUuF8V6rAR1RoTYvr0177egk22ke2IOEWNaH6fsXjvtxBexi8Wa5FlnKMvhokWkUIyZdMD79LhqTJAbXEkFuQRmOxNwTPHXyE1p78yFiiA7mvU6HSbEVGtgT3KDQ4K9EmgJxQSk0s5Oa/vAoyxZyW3F6doitQo2Y656rOnbG9NUfFKhQrNWcvkDy3ZmSpUiuGtsZWDkE1+HpUe9RVQ9rOFMGUDn0E39Ha8ODcKCiQvJb8rt+bAFaMRwc4U4hdFLRoG/LpfFmRI8YYOuLtigug6VA+VHfV8FWUslxKh36ODhqcKhwwenDu45uJ/DA2RA8xzyL4gKDBZeDNXDnxGeX8rbAy6nRORuNU4T+dw6BcmzBsNMQmb1CSrJM7sDvZIJ/uL4pnTIGGkskWpsRA+gVJU5mbO0g2dWh7UwUyvNLQT6bsUKQd7g2YmUzavUJgojBXg5o3+2ISKsZLFKco6BeMKcmmTTrHbDT/LOYdcA3Cql1fG0NxwOG/dNRK4hehhuNW2PYfimJbCI4VSXqCS8hBSx7MIQrj+HqBweO7D34IsFWP9JTREi7rmxI/unjNdKtaj6UagEwVydgc30/S93PQXzWxtXthLGJeIGj4FmMYL3Q9GN6FukNFbFNGPyyN6DvztiDIEiGaHMU6MOSkhqRLoU07bzAra7VApqTT+shpt6cWL88JHC/onJqfED1JKaqtoSIo0rsq1LNzLNkARP1BJhJ9kWLBNln4vh5i/YnDHam6bZNzR2WgKqG+up3z4RLDea9eXqsnH/2PQ6WkpfG720OiGEeRqRKqLnRZF1lK5+MbmB4Acd7NqAlbRNbhr6gIVJaVfS5YCogiUqA7Bo9eRMv36qjpchbyyH+9Io3NC1KocLhtnu2rXT79VPK39ir4SI4JVBAW27vc7q2c4Hf+EcghhRKiRJcKi78LENPKIRHfd+Dq95bUv0kjhoHUfwKaWMh49HsKV2KE8orFT32Y3Kj4kEzYDxsemNg7TFChKO84NSRdUCcoxJYNT3QYyi65HuoT9u0+wsFIJOknG4wE8xsD7KSrpg8/oQzUNH8H75wfAvC74a91I6yUqzVSu5dp0p7Rs0GSXNNHrpOrcVIwLbmr7/BvKLnr5AZ0m5FSnjggMuwXTGixgLNJWc9LZT2gNBL4aJGaUn00P5XjptpzcNZXeRET1JAwmpAyN3aE1LZWXByalorLnOvytmysXIp03ccswNulU+S0MlxyjU2+9137m/efVS99qDjfOvdj741neRDpnqEUtToL+rNHMwVJizdWx++d7aDzxvvpX+tmVHMrc58laiMrXk/LUHlVqwrqFOaKoTHKpFrWRLnNsWw9Nof5IKW+aOxcZaRiXcH71ZMIbR8v/Hg813v+m++53YsmZGK+6OTTVkcAreK+KCIffqqF88u9s9eJMAjNYfvoaNnN+8dhLcrh+8ufnhx90PH3ff/nHjxnkIf7CuKAPgat5XJbzpFi1522uF2yeHckIbnAyMh9VlQE9rK9se7Q7xUyLJ5V1gANS2hSGnndZKcEKeBDcHRWpvueAmvIljoyjmhNzf9b1C6IiyQdfWIUZ2zsVuacto3rH8jY1OoTBLheC6BPnSa7JkRjYz7csykBMTahs1mV7NzT/iQNO5cGX9ja86dx4BSoekOxR/qXgveqtnsqo7dh/q2bu3PmHV7rvfiQ3IkCnmVrL9fJ2ZrVmhquxQrAqKiFraJW9yem41iiGih9SS2UfkYQUjF3EbjpTrIXRwuQwxmOkB3R/P6CXURH8q/YyQuRorclL+u5Eh7OTgBHlDiCS2VyKIR8xm87WXLOHFupJSFKIzObl97xk+B5qSPy4luoFZmHJgV48ffJ5CQeLufNlIUv6L6Ob/BvY5B7RoU+hKlPdLCW29lkMx7SinJcpET/U32L7EI9o1P0Oq0xOnuIWZOKtC2+Hya+4RDTzettgYfDHoZeUZRrOR+jC0bjzlkJeJN0ltyc7mYOS1bm6FmTdTVxg3nL4p9UuNpwcg1cJWdSCvmOwpcXeT1nNtyiL3E8+tgY/Uz/XUfffznjdUqOirE/n8b8LUiUDVJGPQJDq/K/nbRVG3spk05JlI/xDETYaAg2jD8pfgYOCX5r/q8M09WmHZavXdjRs3PW+ahKw8Q/Z03jpPYOPal7+gHx5MBFJCXw3Bj3LEIaANFxlwx/z63v/9HuaCrc4E7aFLGroVx4ZR7lc5HNqSCCMPI9Kg4RZzjdsGtyXIYhQ9hw25ekCuVmos6DkJni93z9DRFgeFWC7yi+meP+cd8khA8PtUvbpHrjwKp6VLYV66FHo4OlqqdkuOu92Swc8t6rS+uSIuhWq3rX/1FcjJtz71PIaxxehMQE/aKzby6keb7zOnCY/GJJaCN8jByuG7Qx4PnJLA0bTAiyGPBY4t+EAWJZqOVEdIb2rq3ubbt73pvYNjg4cGhwwxJgJpbimBADAGQA0R1gYyZ/roujPkx4SMu50UbbTysFN7/+vkqTHx/4hf7A2Ba72mKqGgW5pv+jLqVRt21IXkHQ9so3207Pioh26oP5QAduoY1RsrWgdGQv3T9vBtXxCftpQfvxsfnMfdSPOjz54Tc6mXImueNVkbn53i4xNVX8U4wzr0WX07wTqnT7PiRLxG1GhE1SmT3CLfSHOYd/UiNheOZJo1B28g66dvAlzlJ6+tPbjICbLD9BX9DURFVt49o2iS7z3t+WLns+LLlvSNwXKPHel5g4pMDAaZSQ29YOz4gAf+/m8bj89Gx6QwmZznjF0FnVH0CqwUdivoeh5dJQA1AOV88IECsSRi17n/3drDi8RNrX/+UHwCCcFJUkcBnQWXi9dZ3yFBhGND/A3nh0r8GsepV7Tv8xRxojuAXXrdCcOwdv86aLPkAAieVIMP3OURzEVsr431GyXIf0P7HLdFbwFapthO1DZtUQafkJIqgV/THAMbhLwW4/8jQGgcUFAcWoamTtnSCsnwZANFlTA3CUPhp0fXCWpBMLEK5NaN8ZPuk3Q4fSB5pkMXSJrqUHBJO1HY8bLSE9tY4gBlLiX+hjGTLG1BxPlJ2XF0GQQNf6XlBnDadT/+iH3mUJgCDuvZL8Qaqxw74MN4Wpyyd0htuvH5a53V9xnz5jJcGRt3X+1e+bZz5z4sgsPo9/8vLIs+dSbafc/qPEx4pMstHJI5qskVnOCC0pX69UpJCPO8PHNVyGoMAqJfP1Zazs4GtUb2eFArza+IQuhJ0Wa8UpSQkmSletCAmAhsRfVY85tDcyiifIdomCOhN0xBPYTeFMvLEPEjXuz08+0wXsdvNEuzelXNZkmrBt4W8FHe2Qy+1xqKUiGz5QzGby8EdThhWTiLtWq5HNQgPmhmpsZ+3tlaUC6uZAG7Dl5QMkdf7zXZUEYwmKlYqbMTpT+155B0FR/xyNfSl5DqYafx44J67uq1a6z0mTGrS81yo7RcDl4W6yQKkhPKi0f2T00c2j/+rxMHXnBWLejKXH2xeCyQI6Tv9o0d2Du5b+x344UXxV7TRytN0x6bYeXOSDkcaHADY9qNtAbz6BcrK4AknrhnqIw5wnAq9Q6R3gOm39wu+DzcL/NCXBAvfz8xOXHwAGQrChqi4mOwUppTP6+Ua6aoy7yQlGmLl1LX+NCZga2Fg8/Oi7kJakhDoKnZxVpVfONsgPXU2eoy+Rf4hL+cPRashKOSymx6R4d7Uey4rD50WQjfFGAC2sYSQvX1MB+ItYa8VG3j4Gs+bUIuZ9m2RWifgKwG2DBLM8v1tgf/9XsnNQUmUX2ewa+U2Tfi6Cc26YnSXGNRLFOrnVaQNqESneOhQo2tpiVSI6BCeYo7BFz4Ec2qYG4eimlSm0fbLC9LkHxtPySP1twsUeIcEqUdicS65xY1SQYkms8GldnqHBEE/2X4WkacyV1GA1WEi3eACpKW8Zk9ZpZL5Um/HHemqZR5ppOOYdgLDNvs0Qcs09fiQknn2mIVW1hac2VZa1/Yd3ByqicB6H8tk5YSOhzSC/zFqZmz5nbDIfMr485NGJb8Oj5ULWQF1XZOrviXI3E0II2+qb1iOvpL3gZ8plQK3lpAlCdqYEskdxGFZX3Uz0hXWugJOfNuR4a8TjFW9DdmYVQJgImvw8Iqss2cuO3bW/5idTmLXtnHi2Wdl9I9i9V7fUm1VNygf1DPWz7vCQ25AjY7HRYOeTaX3rmwPnM4LvcYiCch6IH2gB0ikpEgEKgDoXmWpNxhxMfvQxdYTuKNHzvzfYeLiMFEqMmFEEhfy4QpKyH9FASO+2bmSojXXC7Wig2SFBh6jCaMI9DzcRF4OOPSBVZNtpa5kvrVbqkm2grXLVwHbkVfCu513NmKWQ/ZXSDF9WPhe5o9eASvjkOG6SrcP7ti6zdYWHE3hd/QiKQmtm16ScN0sCizVFoAwwSi45QLdPgEETGXTkE4QA5SO3O3Ot52FWYQtExOAxW58JjIw2lUFUFEHMDfS0nyOuo3G/PZZ30j0PJoBT8cOVrx09M7QtWc2oPovZATtH4OYONqfuqfltL/x9ue9SYOZfdM7D2cSU0fncvln04P7tyR2TtxeHzPVKZSFbJFvVo+HvyDWG5sIG17SURGCxccwlObUCCqI8otnyavwAPtIT/Wqs0GqXsX/lhazs1BjPMyVJiawQRxuZndu+DhXJA6LBZHCBOFyQNjhyb3HZxKp3P8Rk4cbwKK1jL92PVDHF4tkUFmxDfWoqGtJ5zOVmmZ68rBKR6jv+U0pNvOaRarZyS1hGp58/AEjERSnsMY5JmGDxTLKV9q3VSTyH/l2KHF2D/iCGm/QJPKN4isEG11WOmvvH+ZPHjAA8nFmwXRdJYi+oo1sc/L9ar3b2Mv7s95U4uluncsCAQD3VgMZKRWINjrALotNvZKdr4WBDnjXojVLhjunPi6ryFCiNhsuTkXZEXjWbC9Q8YSryGoBo06sYDnBUvLgjGYF+9mBL8D3NS/iNWDA6dSa1FOFV99Op2HGdR7ys4Coagjy/JUi39oskVvsqjH/vd6tZKbay4JWgQ1ZGSgWrE+WyqNIt/NyVoQ+p7JWpor47kS3JCHCrDju9WI0SUKSe1isY4Mk8SCsh2hY2BzfAMwUxvTrzx21BTkJsgKwir+mTNgwvSNLu4fqLXt6wqLl4O5LMYTeL9+9jdDRyti1qsnsuUiyHEw5KMV0AaM4BE5WilXF7Ll4HhQHpEJUfUGfCYxI7CKuIWzylgiJ0MVflot5NNyC+G7dA7pr0ZEtOAiIaqKFQF/7xBVQXmGy11Lm5TYldCQLNmXAT0mw7woBwY4ztdDj3KKsoPsKxkvDE2dXQyWCCeW3lVrwKFWK+WVUZbN5mvFBfBc47Ba5AchLWStNCc/BAWBjjUL/8PJUfEfkIixv4ZDkiuHt/alncdbu5ZkvaC7NfqsUm7LXNp6Z8MYFIz70zZOiIH7Kzg6LzWrEliLiop5Ks5jmCPmkucJiRi9w0TZNK0exza2RwYHMe1N+59bPIL24D+1mrUy7w2J2RiyTbR2rAxT7IO/iOdD+R/UWV9GWcc1y4l6jF00iyq3RrXTVDR3XUYmkOJbr1A+1ySK8PtR7YfOXfxKMBVDeSApkXlVFYZzS9na4TDEK2NxJ2tPMjGqWKkxpm0H3F2lHsxikhRvyJYSzS39i0k+6agCmLqPP8TB2taKKoDFpnVrfdvbrF5HhsjqFlABGxrgAmuATfVvAdW/BUv9i9UIklkw5ivtUArTUOiXPhZb7xsOyFbtOkbEW11Ub2z9jBIF6PzKrZxBGo3+1EoxbScg7K093rquWJsJ4Oksukl0UpFNumpDfmLwn2CW4T/D6QT1M9wADs0yTTv/zCQolZNPQNqhZ6aqpWrJqWxu+YJi1VYo2Bp2jaD5JNGJmsUEwDPWcuiSHyrArNmz1dbUW6fGeX7ZVDAtzxxLUKpY7dR76I/TSfpjnBI5g7z3wKdbTU/dnHRJ20QRQ9nchyGqh7IX6aKu6aXVkkpbp3a3ZUxFH0tHe0otm9IIxxGaHb6t3XFrXcNSbeXvnu5LE8vD1tSwTELpQSZBA9tKGhqrZPWBaUr3eK0s90epZKk3rF51aWG3vAaO4yO1t5JWLzQr1sT7rAE9kKAbVcO11Lnm6TKrTT5p1uGyNJeuRWdWMVlKMJQtLYpBpXmPxaTVtWxYtC0BsmulHvy1Q2dALaMyon82PYchrAgSwckaAEFipvqyFXHZw9DNA7INcoVYI4tG1jXLt+hAqVKSODlxlu0+TNqWPdO0cLtM3L+8bfuJOZm++x7abfs02FJp8d9fwF5LVpBC1AoSb6tVQzI3h/PybMqRRXaW24CTaEJR1MlZIafVTbZ59DagMkWThCTR+Bux/rb8pUBwY/DZ5GRh4gBlutszcWjf+GHnBjRu8LZ+aWtnyG0kFoKeMvS2C2geHkF7b19j/OXsxH1yF0n3rDFW3ejZp7UzPBB9XKJGY09q3dzKsfmfMQLi+dQcZVqRC5zv4sLPMGEaRMCYSA435GT2EeJg3Pp9HsL/wfPe6/BHzKJt0xgYTrbGv/smUlSd48FJE+Y3igvKZshqnn6shPomKrgtVFzb9u3SGtjWcK6UxxkBy8kF1A2GlHFTnZz8L2MCxrmaHsozzIU2gNA6syS6s9RcQnzOpeLL8DdjdPYw06YTjYfQqgwbCdutj06DrgxDv0cgCKRNeYc00KheSpaE/aX3bxSceGhobQvsl0dpqiBlp6d9vZaCKOtzuij+rF03lNkao1WqkJ4IOI5wc6KG2lebjzXWJbQjAMMZoFwwvOPXuSHxv8PhY7nTQK3d1kbtSz9ZaCilHwNUVVdrWmOHIG4QfuvfTFem8T3z1coSIAiRt53+ipliDg1i28R0HmwHWgfChMncPD8weg+q8gCpyzwkrgh72baqb/mk+sTZ5Lm1J5AiOkiI+ndqSl3ojgRqoFnaklxQPAE6WNYOgt6TbCU4cfBTTF1veSMdtQiQS61U4rd0XVtoJx5JMnzqSgyy1jdeht0iumy/ybLhkwqEVlDulPgC1nEGBqbzVoJiZYUwkwOzkvgO/iHzcpKYEx2rzl8hhBaa8nvHh/P0sJGfZgROojUn4k6UUfUR/FTpNtA2zIF8cLl+3iZOjGa25RdLNbazv7xScBZMptYxA8R6c2JCwR7rUj1LcOY4FbRN943hYe0y+4nZc85SanSIn8G9qodcagkE9EAGlQYw4jKj4A4HEsBVU9tdM5OxkB2jmNWuUEh1U1KkIiijhoajm4mGJ63fEAR3au3+Z5tfnBd//PRoFQaXHRqm9AzPDmVIXWTOKNfhntPotvmVN7UYwJW0DFZmXFnAp5CLJi7xmUAMMPAmDhw6MuU1qmjxRpPfkb2HUPWY05ufTpnQ3DQ9hYwDsTtxvfMJAyjMrBB88YrlzVJaKtbAC2l3v4lSdhHUjxhSTXy2C6NVZS1QDRbabZgyW1xgROJ5xs2v2ClYMRVkB0/dfcXtVDUQxn7Qc82wRX5EFLebinc+wk1h4uJNc6/zublSfbZYm0uFlZnBzprDiKMLYYW745y8duUJD9SqX0PUkpsz9iwof6aGPL8yRUQBvHR9uTkEO12BIHJx50FqqaDeyBBUZ725JKtqCrZvVryHezibxf0Hf45Cs3XtYRa3vPVqfn99Ur9tsqJUo4asyk76VlwuFXFOso3SUiBYBng4/Ay9EpwYPoZfO3YNiX+wm34WOgCdZQz+2UYTM4YtFuuL5dJMTsgJO57ZnYISRv6wdG4xeHmuBConM+fT4lJxNgf+Q6AN5AJUa2Q64vDl3zm79vA7QJaf3DeWFa173Y9uCLLT+eTrjW8//enR1Rb2BjGr/RCFtxyIW1q2WAuWq/WSYOxWMh77q2U8IYoHYlGEBLGs1laIoZV6gFnMl5bB64wroiu831Wbh5UxVmTHllZk95C2sPM+VjwyOFhcLuUWSo3F5gzM6CAOarAVjq09yL2tDwruUbzioaJDIa6sHCAtkRAtAAwbnV5gq9ZT8r3mCafh9wIVXEEJTHxI1AvnMOKiBXlToCzn9QNZGqMCsbR5YJeKjdlF9pdrlsv4M1XzaZ+NpKaL2fmh7G/yrd272mlOD87V0tKSysGPxqdhTXEx1PR2ejg/ELPpXig19jVn5Dbyute+6F66vPbjBxDqj7sPMx3geNpe9833Nj47pYNjRPCxARfbyq3KRWbFBYavoxCpCSBAMOhUDICijVjM71i5kI4F5oHmCDwyhyStrrtK4lBRiqPqsoJhb76cbUHP2zkhe+YW/qg7dSxXge2n6rJjk3smJgZ5WGaqQThn6Hs5Jf6o1sQ1sBcvd7GdUxiBNyd/WvkG4XyOeoeKjcWUKuIAiq+jLO4gBxkJlPn78cOkVNbpgRmDCaDmxzWqgCXNxACS2oenVTupeEa10ylLD7bMPrQHeUuBfZwa1aikiaGAk1es4dxVlyHcVn7g10bEWuDkgb6vuOAIgsWNuYIR9FgCdspSAHATcr/EJyCnb3Oluiu9aTzSCw2VoTQ65093zpxef/Sgc/dNhPb7HBHxgNK7Y4xxvLKzgi7VxCWC7VNvOC+lIFtL7v6YmR+xKxn+AIkdgKIMVX/9zDP2EQ7Pp4FyA4lfHcfkuDjuxYp21YspxhyxY5OT41OT01BR3nGoSCSTh4praWdb+K3cHcYR+1mnJ9zR1gF6gs39YtAo7mnOBP86SINwbXNjGP1vcmPRoI5MxCOZazCZEbWUuCR0CQIVEDc31eJnj/sAoLQMeQoIXhXidcWVLNdY77EkxFxTIreCQ8W4+/Vzq91rX63duyj+u/HaVfHfzgcPOrev0nPPnBNv7d6FtXsnN85+a+TctPNHaNcIJmjEmWElAg1jxCVI94cmF14G2ubd92+TU+OHJ8aiG5gPgiwQ+tfD3WTxi6pQLM8IrnOyWdetI0dj3DtbPQ1QwJIXxPaXpwAJ/xMcgH0rByhorD4oe+k4A0JuHmyp2YyeBbe+EPrX1+mQNWfwE2OejdMQTXHcK4OCmB49GwNJcN6fzIekZfkTpSozUZuUiT8ht5YzGYJKdRGj2raVNyr5Frrwx2dS0AIqohkhyHxHamNHroSpPYcGj+w9BNobw8gXzIrjU881qseCSkFs69SOXSxVR1piUzu0BCdWrop+lLUD4Frjwp6DB56feAERyhEAbq4Q6vs1hWLaRpAmqtLrK848gI9YPCBRwFk8Axk6eWZ7nkKxYKMqZTpi782XXh4NDzdu9KzvOKyUAto+quG0agJaZN7o2wwPSYeLrDfLDb4YwgMkhLG5Uh2mLUs7kbqFQhR7LGF1fnEWZcAGiCH4WRhcEneedYGRozaHc/i/I8/stK4kPvfSpZxlxtHhHYYphgaRI+oNauOeCdv2yTnzovQILi6Ayf7hNsBYje3ZbwjbkTzENKMKcHZpSZyYAsb1pURXl5uNjAykE1RJNFrhzaVJffUASLlgyXNBXYwe8sgghN3TXs0fOVrfngInaP4aH6ZT/zR6tP6nfwBxkBoxKJsl9znGTyjYaw/Obzz+oLP6nZDtACnq7IPNj1/rXruOgh3H6HVuvdu9/ffIqJXwSOOOJDPCq3kZmIV6w7qVLdqrDL+10nHxUCe9NDSTa1kIKgjpB9tGBs+KZkFRbbMzofpApuWmCpnNETMZ/g5qNZsw2h0DamWuL9WbAdMTFvldAIqOmj999EQ239q1U0ehizFzJ9SJJZKqBG0ozXB/YPpbkq6TJOR4wTpm7aSw4cNSiRX8hVfK7ETCnL5YhGPv0dR6am6L2fmx7PNSxxJdNBO9I6H+sePFUhnm0uMd4WxjeMezv8gy9pWu7Gckjthir5gSxNU8MvCzRDZ1F0elNQYWSLr+6OuMdpFb/rXSCTBEaDGga9jtl+Iy+eHw0I6dOx3utEFNGg0gHljFN0iPkDCuITQNcEiLHdjgGx4y1i6Ey1dwuOSBVxT/t2Mou1wtrwzvHHrGdsfF2D0o2VymOL4C8ORo0qkuo3J2mZPrLZXASrtDf1J8GdwHMrY/MmxzceRApQ38vVhoDZYDRISlIgZZt3zmJKJINWTJb4p6mrUy2VoXytUZcAvRnIDT6V5EBTgSucJ+lnZgFnvkojOOi5fnVsg00//naP2ovy3/tLpZY2jQli7cUPED1+76zTc6Dy6JO3f97evd1cud1TNrD74ksOGYe3ZI3rNgXinNl2YhdLxebdZmA5dhZs/44annDk4V9k4chuNRBl5b/MH7COog5668kblYqzs8Xxnlvc9uMAXB51fBrqySc2F0ofoAGgQtNr7ILQdLdCLFTrZLwb0qHodlQkhHBE7WRGl4DEVd8et2GrSGRTXgtIM1r17OTU7u30MPUvBT2oALgnsvTI4fFgxg2v4SjQI4NQXsVwr/iwmMDRh4rh6XO6FzKHeI+5+3sA9aS/EpgtA8M/QbZKHRJ4Wb8QU/zUYS4sCFGOdH1sLJaMey0RL0vllvOLrBCDuoH8I/0S0Yt0u4F/xss4IVoE8S95X+GdhiP3iK5MRoTDxYS7AR69mQ4rWXV4xNq58EOhxwU8edGHPL2QeAimaifvNDPaC8wSHgv06eWv/81OZb4jif6ly/3rl8QUgSa49vrD18CMfcKU0Yng3WCcqYhyUdIxuLbSzOFTla8AD4d9pUOjmICYih5dLCYkNj39F9zUCwDM9vHxPrNg3DcU6kN5EZ3+lt957dvWtoyM2TVmdnm8sllIufHcLk3RFNjeyRKmoke532TwQztWq1oQepGhmKpvOGCR4S3tfmtKTmKYvg1oSMckLcYukcXGcpf3sObifD7KRtPsvsNz2W/d/F7B+BUwz/zBUE9z+U2fHMjjaaMKED4iIKlvrF0HRdegjJIcRLCEMUrACsRLUmfo+CyIkCx9PpsLUEYBC34RFnOSUFRYKeriyUKi+jy92yYFlQiJOT34adIUtTXp86cIspf65Sz0YmT6UOsLdSzOWnzVmfe8wkYiq5kIS+0NbASGeuSpo16RknwjIQ5SyhY9VDtBMPk7cGBMfbs6udS7WT1dfxUKOX7nQ+uQDw5XvEbM2Ib4hYRdCLtY44IJG1YTA8eefGl50z71NlgtStf373p0fn16+8DymmEFWdMkKsf3C788OVSNol19Qh6G/MPIb5eFhFqtiZUS0vhEF0LBkzAuSMswIJK66di8xNmFaq7bDIWWjkfKC19emV1wSSOgqqBcjUFz4iAF+xTrBIWQK8wyuhe/4sAhffWX94i9Qz1D0xz+JiodJ8jLgsTXn3o/s061YGSNoQYdti4N1rFzqv3yBAZ+rE5smrG4/P6mu3fuvHzqU35RVnJJ2Blq0N0b31Cd19jEp79TWrU2qXENa4c2dIEinq7zWVG3e+d45dn6RwSmnRXWOx7wR2Y0exE57AXYr6zVTavuoc9wjPDH5tl3IOE3hccRumeqbEsYa5du9C59Z7nWs3GdbYWoNrN70DQHsRmn8Mia+3du8W6TkRyju6TwQDUhaUaSFAdBvRP0FOcyeCcjl7rCJEPqCqfnF2CXTDXNAfiAYpVclfJqUKgcN/QPZhfuK+F9XnDhuzskqpMkvHcNYSSswuCiE/pdmBkA0Ga0WIkCG174IiRu0ZutY5BBTxp0dGhvN+vy6Nmo9+GNeUhNGimejCBRmkjsfnuDAYQ7Kg4RdgCNu9a1fahnWSPl+mZ9dLpitXpbosIwG2Rz22NCcu9JAv/REf7xr6ze7k4Cp0EmOTAYRIcFj1yLNDIwr2BN+AVgEgUbjAoLYZB82NONjC0baTG+7D0vDryC2l+YcpqQSZQn7M6oKnRmnC48HXr33VvfYANO93HnZW73b//sbGnSvK/UMcYUJV95JGCaaKjduPN9+9vfH9nc6PrwlaJy8wyNKCHiWd018JUkE+ylvEh9eJP1VAl8JPj1Z/f2jSoxFQAklqxeM7Ze3hhc0bDzde/YE6ZzaLARvllagROtdENVJqqVTH4IDqMe3m1vWdQqgQGwAc+YtoD3Vct1a5MJcKJsTw9geNbXVvnILqvc1Xbq/f/tqVEdLRJKsjbK5dMNL/nH/6n/nfMKifP0uUGvWLdfPayY3PTsGNfGUV7DByPamPdDWvPfyU7jOsnK983WmCzTE/UzhmMQbcd9zyjfg7FVUqATfJAk+yKDgSuf+oXpeaJ84x9tyPcPGt3hWzsnH2i87rNxWLZLFymzfue6x43aY6uy3f1jNObl0b4JIbzG0T8hGwV+Mk1CfjEzkzuMb8ictd43LMc7eE+hNv2lflkWCfCPeq6mvexdRwuJb4XLwBWEcAochrmITi5hhs1muDM6XK4CxNPgIKiT8B30beIZWsdmLpYXGhFgTZRrVuK655i0eOE3kSy3GGr7VtCEXmfMeabYeJ4DzEbhVS6ONcBzvx0mwDr0PSecthnJBjE8PMwXVRU8dPxRsAcB8Ii7OL1dKsZgKl35RvuFhpQvyarTOUL9QRWmw2SuXcicWSoDcq0UR2dmmOvV2xv8Zz7CiOKMmqnrbVa9GuyFrnYnrTnD9hm5wwkRp2CV5CUA4+TOyIfoKoOF+mhjZgEt+McL4P35kvwsNWB4ysd9H1LNWz+iZ8qVnClK5+ZZ7SduRkbLWjmyqvesLsRU4xJFh5+7on6/dI6FLZ5phzv3Zz/eJdcQFQlg/IBUi5ks+dFHdDmHDtjPj2I3Ha5eJ4tGGMVKrmMol29ekiJxw5M/ASpuHfZegoGtiBJ8ZJ6W/VqMr+HTH87rsfdf92pfvXk93rn6p5ocQm9LD74aub718G9amkdbHjpXApmXMlK2rz2McKYUBFy0S3anMezz8cm5lmqdzIUpahUqWe88YqK1p1FHuEzAPGPLLBY6m4AllOwJhcnMf/VlTL3tiePeOHpnImxC768GlhBjxVtMHTHCXAE0CxBOHEcsUFrn8Uo16hcdytRVwqMRsLRJxqxRMGNpCJOw3R4ugcRp0asZN0oRwChahL+ITAI4ySv/KeF4R4x3NFqKlSF1/UISi9CM5ExVkwiYAxsjS7wnVylBrCsfJwrPp4Oher1WM5b6IBMW4Qizs4V6sug9spwPuCf3NJLH2jeCwAz6nZAMBcg1wkMU+5TIYaHATYauBsohceBdQHKxn+WdKRROX/CEKK8WtIJSqQoDYjnjUk+Z/fMZOlH/icryB8TPOVzjiqxPhmhE/BpcNPYbTUiNhg9Ejw3uAalR2mXziJFKQMs2pXne5XAUxpVnlGqN006WSpbezEQo0BNMTcMhip3yY9riupnqyNJyst/UlEnWguLy3vJrWuVpbnTRa19nakFfNjDqNRzWDQI7R06PA4wzBr2x3nxxH+EqVCgtT8/Q3gIi0CDQlhv3yfCPEvTJ3lRaVyRMmoreIJFa+YwvBbcqUCUqawVMH9BH5JrUW9BEp1WobRXTxmFd8A68CNIAwpg8GrAEqtD5JKOKJBoSvaHb8czBIzCSstC5LjIPpHyIhSP7tEqJLYYxkCJn/wX+riIdKpcZWk+uFLikYkmVZWOOyB/8qNsB36tRVmx/B3oTlWOnVq27rC4roxoXfDH5Z90XJfSfFCb2ZLTeyNjFQynAS9SQIF7xlmPTPeHwWbznC72/vcOaKj/HkSi+oqCmzXiHHf9NxJhkDqj4wMDsXs0iFUmw2J95HpkkwmzgPS2FoVtp2U23zyNi1WyNdF258D0dwB7Juq7enIfk27xh5yyeHgYPLFsPAfMRmqSAGepGiM6a3PFxYMamJhYCPBFTYtBBsQzdRTQ+VgzJUlI2xXn4CKLZvF/dKC/5LSTUhnc4SNPSqzCsveaSm89YlwpL1zUTW5FRUN4F0oZ4W2NuCohPHb5WLF0GSoZqMZ+BJ2MoZLPllsiLQFy19aLhFuCMEx+Oz5MI0mYJS5BdCJHv30wfspdNU3sotQFnlHPgsNW8xk8vqMFuCEIgxxEjQQmkcWQnB/dfFIzVFY8SiykNPcezXd9FDORT72ZKDPJIS1bAu3VsGOWEi3R3CvjTbnlkcaVSpJLfCk5NvbBlynYjbo81iQ/z1eZXEHAyjI/DZ5Mqh5XDzRuIlxY9xW26lqOkMvNYPaSlb08ISQP/g04RS0fUvzbEZkxV1XMsSYGnxqVK5TQjZpX5xjX7/niKzWgqXq8cB30gpjCC2qqe0ehdSh6epkbW4VTbDutIYUYfJR1kJj6hQfAfYAyUgLVqPeyMpf+w/uGduPj1XSLAd1N9mTyIbLAGRCuhfXol2e2cWVHc52kJ05PE4pN6iCRjVLRzfjmXs4ht1Rs09MjuRttr5Zem8Uq7kxxz5B9sPgOsAFojJbKgcFnUgbhFMQ0hLlPImj47qmXZaWDNi+g4cKz4sJ/MPY/v0OI6DGhoiuHi9VUemkydjG90n+K9ABZ2MSooqxWH4XBMteUToAVcXlUm0setUydzk4wel0mkIAK6v5KRXxBNabQoIL5uo5rmyCPTkg/ynE0oBsXAFnRbEY4P7Asu5sORB/N5e56lIDMn43BGsEaXFLwRxVBz4plIdETcXT3jQmdEGXJfgDceNohq1kL/IbRcVldU+F9cUFZGnTpvtXcw2R+CvlRMU9ilZv9Y27bDGM7stK00g5Rm0kNXN9blibtCmIfN/XDPBXMRFo5L1CWY1Dzognw4RJqOJF2QNpR36a5pNLe4Ag0HYxxk3G222g3cCGHe0PwqcvbgvmnPl2uHx3ifYsu0hwYpoK5L0sjEv+sozXmjjDLnaxX6Y1USeRzbK4S61XTt4VT7TWjmhV64Ot19S4W+5w7KfpUJiXiVKiPUskrQY8j1q3ZqXUcDmDR1NTs4YmvJBBepJIdxSDadbKFcLfGIjs+9NHxN/5gb2BcnIY5RQ84k70GGZPiTtEugbGQFM6WgkapAHLcnwJhG6wpt0TPZF/DzyHKsPRFnhmT+wZL1BUufo5eeQ50efpSSqdH5gSfMCoWOv6YrUxMP5yMDsJt/qoskgtrzQWq5WdXmviwOSUOKrje9ueGqeoaIJiWvIDfygKqjz33MooZoDIQkaKHN3UAz4nbTGRFCCA8MW93qAnu/b8HzI4WcrZQoayC3ofTq1gvEqVuaAmPW7VNhZiOpAFPTGOdSi3dGpr1RPoxOqrbOGkstJTjpPiSjvGMmRxa6hglhF0jvwTsS4rLwy8tE5RRG2JQ+EUV+h7hO6J85ClUGYO9J00B1qP4JyVKvYsqhOpeWudUA6e876ngiC9iOTredMt2b92nrlfvFIQZRQYntgYbTk3cA5JMaNJcqRu7QMC0GBNHEKf6stI7PDCKFha/43v/7bx/as8WocwNiiYajFwyC+Xd4v+EVVRfx2Ldq577o3O6zc3fviqc+lN8jNBPLu4nnmd1bvKvI/LvC0/vU1N4rY89j3UvrKDi8p+Bo3DHVFu1heNa9qpsVGKMkQhlRY01HkLQUntzYyEKaV8rSj1sI0kEXkDmML5IurDdHftozNzwfGj9adTRyfJLxvqVqugvooon1xKH5DnBEFDkTZbnc+qr0db6s/p4Xy7b8sfVGTLH7iT8YUy46JzTai/R+GvimX8ttOQ6/hcv9xijN4wNJ5pHGLMdKsaHSCvYOwz4QsJ1y8au6eBTeYHTN9Ay/cAWTOsZtTbtWsnJx1zRQgiudmmj3R+m4TdCFOB1QdVzidwNRNfDm7jsbxUSwFCmbhMZI4wDW/vpRqhq/rh6wzZOJFzHYUvYVL+mYOgxKkuLgQ1miSI/C8w7KkJ2kotCImdnTHBz2J0qPrroSF2yDY9uvpCShC1hRgJOW7WiY6gx6aEAAkxWcfcUbOOBL2IDweRHv0DACuU/QSPTD0QLmwo2gGKBtLhfDMOON6MjbNrNd2slTHVmnt7C0ERmjK+UIGWekcRwxW9u5YrC5YfodhvjJ6I3TnEOhtkL3eH6ptdCoZPhy0wW1WOuruHhrT1w1wqLyGGbv/JVXQSZUy6jgecjnM4U20q9M7kadQrNZaSANwZ6lnV6t4nzqmf91uYEBBnPjrxJffEP/NLTDwkSWFHEUjhUJyfL83SLhPUg7aEvltZ/Jk6+LvxA0Is3j8+mY5MPoWkqUlPu510t6eQMKgWMJdh2ELo2C2DrHBXptOhNg3Ya8zOqO75HmfAGIkceHqg5xH2sSV5FlkSYtwIOw+paIr6pSdMhf9ZQY24qlYKDYBVUF/UKe5CMCc1A7XSAnjTok9IOxr+ioCxiB9FCULEl7Dpao4AA3Yxp0TT+E0uShVkc9NQOo/QeRbQEl5x8NDUoEXCmKp1ldiOMQfhK92R5zDqpWGuSsdLcwDBKqHOdUBncO0pNjABsGAkypDxpybZ5dAthCcRFZEt7J5abRy3mB01tnYMEdbONmx840SqQw5FNfz3pDmOzK6cOWxSKuZUxzGNN7yOoVV9rs+AC11LOl4bEc2pg5PoHpEBDIuZarE2NyG1lWnLxIvhBfKmVJ1wkzcxSipZx00xktghpyd4suu6I/DBvFrR/UNyfIIrN68QMcIl6L2gz8zxYiAspmlWUq8OaINOYfG3woAeaXa08iLe5N76Nz+uPzyzfm5VyFpQuK3f8OY3z+E17228/sr6K/cJN11+FOEDzC+7713svnOWPiR0gc7quxs3bhqfO76TrATl2ubCFn+xZRx+WfkklPeO7/LW7v0Z/Pl4QsyB6XdzfA3gEx0R+fBTIe5xVGOoNnCjeafNoXd++HPn3AXyxuxcuLRx+zboAIJKyjU4IQ/jO+28t62p7Jy+ufnqTZ78S6+vPTi//vDb9Y9OrX/7cefRFTlce93+fmrz7KWNO591Xz3906PVzq13xRr+9OicLG7cwZr8Z+5Ra+rj1U4OpalvTYvqtyfYC4g5ASDHa3dlRGdLEDTNFUA7QgTDu6L8eEv1YqOxopMEwb7gCXras7lc4mfGDkxOHJl6/tmQk9mBbtazZXFteJPaqdsn2iqLYYGYlCMclhwcHgDlPxy81AzqDS4ibdmE1RJiY/LFTfyV6LX+yg+TYvPTAgiPlYVUPSjPR90E4GnObCHMql1dKAjmtF4EJYYoJ2hMQauBIP/xrgD5C7xSwb0U/P/EkGdr4PPYKBXL2vUm5iLs31y18ML4lN0v7lBljjmJFP49U51bkfoO7ft942N7t1ABqwNUDWYpGKAqa4zzRQwTB7sXpEghYo1SIQmlRTB+AdiNh9ZzsHuJq1Fsr7pXWqhUa8YNT1crdhJvEC2r0D9hNumBHnDbQppOhQH3BULbSuvPIAh/O2heTFZFx4CR0UEuyHcZ257RNweFF9pyRzjV6KC4aygSsGfEHSPHMMrB8zswREnjSE0H7ZC30HvBrNXP60YkCJEpFaQ7BRQV/pmaOjz2/PMTe9J68k1NXvAk2wUKRYPYxYfEu8u7mIsV6IoB6cifFOYCcdbKdfk7Jt9Oj8A5VX8qOr0Q1+sE5NDM/8h6PS/4uwPVxvNgRLEQZZ5kXSRDF7q8Zjxm7npsvGeGdgLgJy9jqSK4vSUyZjdYXQN692alKHHP/MSOoDpJ3EXgsmEkLEKXCeSkR8TOXRKEcRB+ZODyprxBPlq7Z7HxQZY+fZngyId1HIQf/wu8hWtCnhilNdNgpPCKQ8UQLUC9OU/eDvixEEVKFfvrtIP4yTjP1A5DO6HeL4p1BQTxPTTW7BS5p+hD7+ez/UFlAbM2Quw5cBm8s9LpxK8hrju7h5OdMmwMaeiq2bqQKgM/6fPDwbxY96CWPaS8zhHOk54mfvqvWX3A2YOkVaQa6pXS/LwJeCcpg5ACgBpFJYFoC/pdnz0iDhZsR9GAPL5cTp1es7NhTXUTXkDdTI72T6ACQooSNP9O3mMSj7nBekwtwgkXDAJmPMJnyidm3isUIH1foSDv/2JtAfy8tx87AX/Zt26N2JfCrCAIDU3WjxQoV2ePAUS/bDu3XzxI6UrQZdHNdE41bzcc3uFCwAZ+o8BVc0f5V4YvZslP64x+gLl6zPf69YsXfKTXtilQDFRe5+bo8RhDIwDFZCpY55ZKjQbK+PT9b71niQFtLqVcNYWozL/1du6IxJBwdQ74kWhd09CjvGr5aW/YZg/c1dE2X2w2EI9PzjX/u7XLVq6tvXBxS2ZfD8Arj+OfBr67NmDKHwEjxQVIR2O7wu1jlKa9g9+M/FL7gGY8EuJCH4x6ww6siKDcZ0Xuu733smfFsrNz16GgBpclAEN7lWCh2mAnMMHMl+YoDoqr4tPq1ate0auXqye8RbFp64vFYwHXNVcNiEzO4PkGhwpd3SArYscyx+EtUBN9n2EukcOMo4iDkBrWDltk64VLKVHzTtSKywVIpRpoG5DFIZgAkjkwYQUmIY87ZZDltL6oESEs3HMvh7qrkOeJ6OLq9WRIAjkLs+WquO7TPU5EhOCFN8XEoeO7HbdF9BF3kesIfT1oInNjzxcmDoxP7VYO2+IbG6/8CdAO5ZpJUMFQ6oXPROnf0wP48/hwYcdAEjwiYdBF8Ov4sYFipwvhOFEZj1KWAvfsnjNwzx3x0/1irYRBa86qOKDE18yRendSKepOpofNN51x6SF4c0N1+m0eynyheZiNt3apcDX5L7uAJlWgUtn9nuJFDQOFbcXRhC9l05FmPl0LHo+l8gQ2StGSrilv273HfwrgAgaHJW24p4FzlZVeE7270DstyePL580rpHI2fMNm0/KMHRZ08g/QBkgK9dGW+HBqHHAv2kcr45XjpVq1gkErL4iuP3fkBfIRA31AY3Z5dOiohj8874MTmjiBc6iGGG1Rd9pe4aVmtVHMLjSLtbnoB5ON6vJoNizMa5UF3GUqm1bOeGbWV91PbkSsCJuhWMPKyD1xS6iytmTnOC0LpCcQP+e1n+IIbyOcXVznbQnwOvoUa/Y9zXlP6yIlBTVOFQIBqUnAvQBbyEwEC1GqwUu46ORb2Ao98NpgaisleUmyX7s/YFr8wW9XdiMjfZfkSDBVL8x81Lhxoki8+bwf+ijK3AJtX1dS6AtldKK3k2VL61wbPRXr4FAJmVeyVbCZBOyq2MLutEOfy2iRgRbNX9t2oqyXlpbLgeZDyam2Bw4H+MeoEMDmhcAvrmL5aDKYHd05MEXMAmxheDA8NHCgeiA4AVjoQpBaCOqjDcj2wdjoU0vL8ne1Ecw29lWXAuPBJII1jIKedbYxsKe4XJwpAXj+c6AXEbRkUgjqe8YOFcSdWHhu4sDeAk/sQIuXq71Ft84E107aG4ZTZx+OoGFCjWSn2Soc8VKx7CXlpRiw9jie14HnBGWvT1Xtx4fEohyct58mrLSLUKmcJARWoO8ItbOZXHvuhCHicbm6kC0LGl4WJ6RW8bKz2tAoiYvYyGJzigVVrj+jGgl6gl135MVi/djo0NCvf/3/0Qb0wbOt/23CCtFMH67VUnFSnEWRAwIUQMTFK6UPb+jovdIozR4Lp5AndXhHv0PgrhemJl4cPxw7gMki7DNPOUaIq0iORHQaWhcS2MHKc9UqNt+StU4cEPvk92P7C3vHnx87sn+qXReloPqJCqGv9Co9NisEhuLsCg6qPgCfhmeCv3NTCUT0qWsUIn429h08+DsY+q+eQrajvni0EogZ95JdzxHsCpKl66mpoiA1c8VgSex8IWsITlshDBFniqbxijLkoZRQzzCtWi7NmYEAEEAQkrnKSkq6IrpycOOumvdFJWLPlObaGbTx1oR0GgYpwy/0x8F2p6VLRt4KaO6Rept5GhoXOEAWRHspDgIwRxCdHXar5dIq+O9FUc2hib3kDIpqnogjqwT42xnjDEp+7mqeYyYZ2RzR34y3uFIIZ1y3SJCFPAIP1scKysrdEEchqLwjNbTb2m3WU65Wl8F3m8Luh/24hNEuxEqnGiCUokhena0FRcrnBQl/wRSXkm26E7+nw2UZyj0TA8VsCO6azM8if2y6W3O++KGefQxX7KlRw/eezXl0/4U5CGNiw7eypuQ8ghnXQkkwmouNZsg3gs77aIZ3I57i2HPPrWsnXfbuFzruKZk3BVPjGQedMPa4LitktDgHXCroscVmyAnqJ2qslGZT4KU3/AwJ64vgDBh5/1v19chAn0ZITXW0WMSMBtAw2xSqoAzAu1XZFQYMCUfMFRpemWrp3JaudZ+JKyjkoLAcLZqrmGSY0iHIlr0Z6azKToVt0wyj3xuvzAhuIFZuFCDyIaWiZNI91jCU0tk1C71CTX1IXxTOt6Q9niMzqkUjl2p1rNTZ1AvIhgtxIxEfTpffThIirIJoeSLiH/UJ4ElCBCVjGAhspHbQqFp7QX6GfDcecvgtVIcf15GvAq/LOG86PCL1chAsp4bT/SFFzQiyfWwgvgJTO/7vVUGSECR03u9e/3T92hvykbiivWzTs+L39CehEKE/hcA+L1vxdg9BvE7SlMZsChdOKPpUbX78YefBZ53vvwH3rtvnf3p0fu3hX9cvnyEcvrWHAJO9efJk5+wD0XKLh2Gl6tL60LtVRLcDfN9L70g9DMP+ko/X7RvdK3dj2nLUt/H4/bUHH1BvIX0QorVzyj5Gnrra2pbxtpHLG3cz3Xa0wPRXO4Qm8iteNGp+TaId/YgpdxKMdf/hM7/yng/EJgcTyUxQrAnZ8sjh/d7xUlF8LKQur1H1jkEcfqkBfusQhQ9F2eSBVIcMIT2jHgyd5YDNEv08WG8jr2YIqN0nlDa5uyUl0tRgsilYaKQlO9+mLEIStALUdfh3hAXWIn7mt9Fs+S3xb9s/WtkWunhCR0tBfUTh5HC6TQa6BmcjkOsgqefxEhjYY0omIWOSBpC8QAESGzMCiCPavfKtPDgEVW/AWzIOs4qQ+z9OH4ERr7kMV//o0bmn/5fKY0y/GuJqL9OfwcvLJTE1Q/8Qp9Q0BgNmtNyE9yf458V0v0OjZO8K3JmoQOfPFzoP3u58YqS9nisVFypodxrRAxZZgiYSsHHn9e47t8zpQH21y0ecK9h4/F73G0E8zpF7K2Wi37h9l8D/AXX87Ztr9x5uXLrWuXDFG/Y6j052Pn+Dilk5H0J7NB4QyWBRTsC0OvQFdPc2Yq4kCooElcSjADFiy0JOAPPeTAn1KxmvIGsVU44x5SnLwRazG3jKD5jOxLa8JHOGjMKB0CydiJ6AmAM7JBXBCKaw3NDuduTA5KHxPerJ5ME9vytMTh0eH3sx7QpXbkFY9AokdwFmBH8wP62FF/CK7D0wGXFWVnxMcT4ThiCkTDsgeMciZKRlHoTn4n8Y1qQIrsGqb2kzaRnPRLEUmKKT3jWa4o3P/9r9y2VKWqXjs3oABA9o22AcgGY9tZkst+bN975ZP/Vl5+P35WrhXtgmNfNwbXV+PE2nfFu6DSCKiCm/8fgvmyevbl47ufbwYuf2x93V78VdR2j04daPQnZP7Z/skb0LD3zvTGwxFk09M5tgPeccKMtuMuJMM/CMrYXIESwTRT6mfHG0SfvrcIiXqWqIrIjZpYHFQTIRGVDffNG5+/X6wy+6q+9YecnozHff/S4ucRB8oiVcsTOIUJ5Z7XZXMS2SKER6RUxM5+5V6NbqGbEXaKutP/x8/eEt7tDfT63ffCOeFP13yDvAayeLeYsrP1tsG+hXWO0l32jTSjyXmnA8cej9qIooGYfL6R55FHPUtygEYlA6CgLuE5vavfXXzr17yE+FbRLrRGx59+ornVPXfM070CV+8yeK+/Ujx0EcAB1nAvRKEsABeBWNyLQHW9sGmVd2aSbTbSZVzbq6T0ArvBUwcUs/Hnf4w8h5/bZnqeXs2e5H39MdARf4ZcDuuHeLZor6A8H2NDEAJn7qWvfWxzKGw7gBn0Qyd+oseiYsUKwcL5OeVShJ8kjwVUYlAbP5uUn1p+3co8gihRQR+yXFLryz1C1G9IZBJeCATG/T+wWoEYIYUK4Fkm011mjY6777aefxu3oCiSildfdDplHZQg/oLrzzffQWjKBaCPkVKqUNIwQF7TgwYyVOBEjBD98U1Hvt3utdOJhYVnSJ5Elv4hBeJMiQkfla/pIm6wRFSon154SwTm2aoZFcyfoH34r7HZgIP8ymhZ9GLgdeu9t/2Xz/NI9Q9LHz1vnOw+82Hl+ntGna+uwK5wXD/CQtVYo8YrQ5ySlldiZpSQUDSqYTYWSAoZZ+VloSvDCOQPoOYR2yCmRDtsuK0ltAPlAW0BD/gNNuyyRVcamyKdA3JlV26L4RY/OmrzPhIO2ji5qncJRYWHU2qTBPYqS00bzubGL01uiRBCCsBCeMWw+SfNZzATnqkLBxePzA+B/G9xb2C+Z47IVxMWtPUUa32OQ3bojBreUKEWQXxHcwqIqfOsOQ8QzlL9vzNMlppC95zoFiTnKdJtER99Q5vUqXhsf7RzsYjXATM2YiNdgz2adKx049N7a+OsiTB8b37y+M7d17eHxycnyy8PzE+P69mNwRC0aT1JtWK588a6HotLOq/ID2cWg7IU4Lv56pVsuc/B13w4GxqYnfh4wZVRNSnvEDY8/tF3sF6FTv7hrMl95ZRzX5MMWQT9dvUKv7rsp5kShWXRad9jm3EmJz8cPw62mtTg0KOLaf0xFFuUaZAXzbb8GLNkhAiNIv+5SPIMtJZ9Si4G25GG/kMJGwxD+kOMGRgTDKkbsGoISUy0uw7gswjiJcNGpQhJnhIU+KxELuPySgDv8E2MQ6FmPrWLAyEpsAgsRR9uhKMg9o9xskNFc4RuYM63hecjO22xoOJP8rD7+ctuXi7DFBTuspMWXlIl6aBUicZMybLIRenahXHPGUfrFexwCqZYSG2kEpGCQWt/Z3W6cwekvapcvN6FlWheg36oeJnVhiHtVEZwksNBpCDNF8atYirhmXASB1i3i/8kOEO+eWeT1UPi09lw1/mM7HjURhyOIdGM1LpcGPEOCafCEXNaLjl6YmhihTHyjiEfkCb4XicgPgqFCixKnU5VarAG8ElCBUuqysvPUBExIQiOdwh80Ws9plBI+2S32/ta1AOVoCd6ZmTd0g+jPcSS8/u7uwexcG2i3N7Ua0mCIU4me1JfEHhdAtl4sNCG3ILRVFHRVRpbg5ToCLrqGINFpgM7qZjkgOPC1f81KJWRmku3SO/6XVskBLHBfg23e6509xoiCuAXVTR2aalUZzcG8wUypWIEfioSPe2r0HHg4Vk6bhACPJOfQx6Bc1bzTrqt4/dmDvxIEXCvFXNtWq4lf5t3b5mlUkXsLcHd7ynOhIJpUL0dpDvazqtN52S7PHiJtDWTuIPUeoWKslnb01vXNCT2QfkL9g34C2GvNJSR9AeAhugJBYJtSPabfXiDfdortOlOQ2s/U6qeIohc4IuP0U56onQGSty3RVAUaJSpf+WL9kGqkBpY854bZrVRYw7qUi5YB0W0Pjp5RY0M3tFENRODz+L+N7pgqHj6D3vP/i2NSefRmG/c5Lb2VzDhHbxAXVqvUhLCNYm2ode2l1WnJN9QL4xJyo1uYw691kWIu3cfmHzrW7yqpAeCdxvZDi47WbndOfgnyFST7P/bnz6KQQp7z/PPOWNwwCIib13vjsFMmPkIIUMUYo7c36N+9tfPvt2r03uu8w6og4VoyAcfnLzp0z6x+dYq3e56dEsbXHH3ZuvWfLsI4+2hvRBMWl6wion7wmSwgVNp2yJi0EBE3W/KmbhevVgOaSHVRC2PUtOKkges+JSoxuib3cpNzAVGIL3m6xPE28F5zF7mDnBFGbKy0AIDChI2OHn0KXhainUQ9PQ99wMcSqkryO3NrbSGN9eCAlZIZypNGJoCf3QJl25NfJ8o7tnT/e8rcYyu14Jp2UNvaNr9a/fIOOOBhNX/2BlKykckN8nM5b5wE3VbfYkMpp7d5F9iOwlFhh4k8NMXoLWV0sbOvk+VCZR5rLiizpiNMGUy8vx33j+w+BLhXZhQLesoWCCahg+NT2cL5WpynZ+RoCqIDxAzgSncJyt5NiMZKCMLx+4bBDJFoFkN07biMM6ZGTF0b16E8igT1hJYfE3TP6dNSV2VyNtifXLwv0ckBGMuHX2a18jtGW/fv885MdQ/9jYQB2hJgxs1sJEug7NsXwPO/XQxwny+ZUHVeLpaFSp0HdDM/0TIdrfWvLH7IPJhAt6kBpzwlpGP1pyghWYFgrXOx2fwQRDCHSawHU5igVkG6YVPnEkwjmv3P5Tuf1m6ZFETh/TBruEqGcqhpdg4e6L1MK4EwMbY2LQHjiAvB2YUvBHF0sbLHOGGp20lfIVObznMt84/H7nUt3adDSGs/Z2AGoG8Qb9pKYbhmNojHs8enOjS+3tfN68nN4o5cMHVSpr81lUTAoLuHLFPbKcJFjJ3LZCEp+UZ8LeB11tCDHBoebRU+DE1+DcKfxBQjD55vv0uW1Hz+wZqV77Zwn3RVgznCSzG3Akp1U3xdWxOXir9+4vXH7E9pctOP0C+GnR9c37nzKHoW06c5+0fn+a9EC7Thx8zLavtOv395coVbIUAmZcIiCYBQIel0sD5+znMq+YGU+s7ZaCPqmF1RVhzk/IlmtVaVimrQekGWn2GxUtZlkLHK7b8Q4JfRKclZx+TpcqcV6J94zZm4O9cR2RnbvT+ZDZCDFQ5CJrb5q7kwhpojRgtSiIR/cV4I21URa8cLIG1vI9yBwmG7HVt8iEQU2NDT0TpzJsMGkKIS0JdvALjTrM2mUHz0fyJYOIpg/Gz+nN69e6l57YJCg3oEm7NtAViZEmsOmMzgipMDUFdyNYtoERaVi8B5UCbPLg1GhIOr/rBmlQ3IDhjfx0NErlF7FqwyqpkcZ+zCo1UzPCFK6oVw/4hEllJoJTpuqS/WQtGdWkIc6IQcUmrVyvTgfpHbucEEnhydaz0RoHagRPBrhdaRzMQ74dsCxA/6WHEcdYO6ROiSW9K91mCxJ08AqmIJLVQ+nYIOSxZf2YbGkErq636msSifZJmUdeus6hFRUQnH3xdDg6V2iPriyYam8ipaKTncisDkbybLoOVw2r52kxC5wxAZVtox25EpLTNhhIJFiEg7luNe9eaPz6NLa/euipc61m6QeIr+K3u3GqZ4srY4QFpsWpyj1/3SUShUHiqiDHcBUzd7k5D5v/eGqoDSQqRlVWQ6SRPO6fvvG+uUzYa9dJC5Bo2qkFYltJOK/B+o2YuFoPolTuXAFarj6GjlnUJRCqEe79IX4qHvrE2Zn3/tx/ZMHEMwgPrz02dq9k6IyTYMHCjrpE+F17jwSr8ylkQ4Wtz5h9gk7v/bgIrmukHav89Z59unRQimg0XsXxHYAbeDbfxOTzp+gg2Bk4+HsWdBS0k0s2aMqIp7EZiVJ8Kk0ox8xKRFQYW5kxNN8q9AYE74IvaqAkgqBNJjDx3gMyZ2IrSM0HlEKVDHXbnZWz3YvfIzMJjtaWhdO6LVG2MN6ziH2aYbrYRskBdGwjhHhWN2kvp5l2oau4tUNG4CuIPPqJ0A6qayhivedXayWZoOUz+pfYrf/fGHth2tiUqZTuvGKqu/c/44myE9n+jGqunFlgFRAnSS06XSQDsPPqlxKv3Il73+3cfvHtXsPBJkQVO0X6H29UUX1I+0emJFL73S/WzXrz0e0rTz7sVFdDr1h+BUq63gxop/GSeUWAJokutETa3gRg3MJbQiIFdBEIloikwKomrWO4vI6wL/iboukumg1Y2KSk1UNVm7J+Mveol3OS9v2ao65u10z45Q0ce/otQgZc/3hJYgGu/cFPaFEWUDpH/8FZMxHV+G+g+CQnz0dDoUTAX1IA/WJRPXRUOy8KKIq5oI9v986zzLy4w/Xr7yPt8sb3a9u8Om8fLFz6c7aw0/JHZyEa3Men9R71MnPKwdOjdQh7TzfXb2MbvazmCE9js+XnYmkT8h44wefd2HS8bE21GcWM2QZ7hMUVA5XuKnxwy+ymD/XXJrxlZOEFMtX9KRscvsy+/TAg288YgK7734H4ZKX7pAnK936zJ28dR5h4jcufi+InYKONy0MYrokjDoog7zfeqmdGe83iSwdsRneIUL62pn7DSpxPvi2+87d9XOrghE1miD9WzRpcGysEvl4LIDnEXuDkixeKC1HIofRLEhTxkGPMJNC4ET3xAI9S5lF2O/QCEjppdQSR0S59NF+F+xW5/J5pasCzSaelfWLd0XJ9de/65481X3n7NrD70DvJxgQyRAiK+iK4wrzE4U5VSJQHe5cHlLYB7Veo1FLqVximArlac9HiduPXG/0HUyZzJlihoVSgHNEskd3BH0aZRQp1JJ3AX4CoDeEIKiNKm4pMGM/g/895MHuufAxqQuJBMHcoHtXJJmLDFY4e2Hj+zeBwOK8c1yf+jZ6VUfDeGmtPMof47G/ip3JAsekRyio1aF4XhqcFZwsdxwnwkIdCXo30QM/OtVRbhw8Cujz2aZgX0hrQpmvIrG7WGne1YNgCaYercTGk3Dx8HfvI0CTpR+BzmlBe95RwUibr9xev/11RNaQzZ4IZmrVKiqi5SOEqwQfE7NtBG1dKjUw+e5xSDgwX6suQeoFLU03aBLrDUl3hYxYBT+ZhhhosWzj0v8K4MTL5aCyEHgnxA2D8K2iipkVQHpls16VAqK8Z4dyJvQt1AwG7yqFTdcIu9waFpg9MUY4RdF+9qjjAfPFy2jQXKxLdI9QOmv/cOvkEhuOY8DhRtljTayKVSmsOvJt0qd4E6BOKODtrLBfDA4sZU8xE6NwNcItrMbp4g/FhktFemiciPBpWKU2wrRjgvu5Iuh8cIzeh592H1x2ifvz+OW5H/XEqSp6Fm1IZmiwM8ZFRfwnX304F6wRJqMVBA5eflOZq8g+pVmgpOEl5EtU1InGYC0ReTcoTIJIK/3K3THA1NUnC/3tFU8bs3Q4bAp3pPhautFBpsIINXOWPAjHHUN3RTvQliiVcc4Xi3UAKNglBgseOHB/QzzyqI0mjPc/vNVwn4zEicvHd+OEYdK9FtazKy9DmyMfogkirq3dbYNEqy6i57dop7+gMg5IvvM9CZ6dS1/YlrxblxWDRNmixHVN8hO4wPz9DZDzxTY8+0BNLcANeyCffXjSaQE0uooewlvsLjGvEKJrrql7PUMzC9OgX/IGkBxwJTjBDLDc+q12hg5VRjaciRKr2LmJYSVswAxMSwdp7WbF7xQ8QrBsl3oB54/5I1ghIRB2L97cuHCZFUx3z1CqLk/lBAPh4/f7xycnPXFA909M/Zu3cPjQHt27MDheqqLCsbV9O3sOMkcz4s2VZhspk8vhCGB5ewBacGyEkuZTztjWZQqYw1tQXCAqQILCdRW7zP2QjYzKP0J5SdYU0QhpsjRplnBm6GS4gqQ1GDS6/mWXJEKAigflJqMxx3vHnx8/fFiGtxjuGhFBQEJJsyAQiS628hFhiz1hdUi3z+Hg79zv3lhdu3eLd4Ij9hf0BmcuUKi6l81yZAt0KLovFM5EDO6E9jryiYSyQIc0wflxHni1dTAVhVxIceObsduyulB454PHNRpTR16ORkPsaCFbi0b8EzESR+b86c7lL2U48X+dPMWYE/bEmVld5W5AuJfuux+RUcAM2jT6k6haIHADmMXpxGZjpsiRyQp7Z0gi3IZTGQ7TcPpvm+/eEjfB2kO2c6x//nDz/U8YiyOcF67HtLLLNYdsWwn9RG5PK5q40+VCffwl9YSmGO4zjHYlb+vOpdeBv0OzUOfSK90rd9fuXxfXW/feafFJ394rpDYhbaQ4NtAI4sH89Og6GZuUHnH9+q3u1VdA6n38F1ub2D/xcRIgax5jJ0c7dCnizuz/pgcSw90Q/8EkaFL/GRQomTQmg7IoMu9t2w/HiLUmM8/GnTOd1S9JxYJORrRkwFCcf/CfJz8T/weawnKzvqgZfrm/x5frqHBi9LxR0FuA3kl/7somSrHTbJ3DlkKbkf4toOGYjRuOvqQalKJM2gycigg6fQXiZLOS++g8Pr154yHxPGKbkIGN8UKuvtb96L6NGkJWJk/zWNJIoeHRhA5GRFRdGSwNrydkguxaBnq4N1FX0o7J0lpR7Rv+0oK6cy0jSXhuUdlNLaCCxckDEg4pnRQSCst5FwVjCb5k4ez19LJK8F0f6NO7Ktmzane/gGm70naYqtWhPDcy4ChCsb3UUcWfhAm5wfFfJW7gGPyDR6b0wHNNhlV5xJ/Q7SWsIOLzEhcVy0dQnmSgG6GXxTv3O48uYbJXHF/bQTl0PQ2AA5RLC4sNybmhtops16PWDWzTPvJtc1E9usbZ+w2EBcj8Vy79MRyOSkcOKDYID6HxOUnMi47w6WAcICxUb3zE8tqBqHrI/SnjNPiyNWm2zPsAGdmGhmOyETMKEqFokIDGLqJgWX92iKXxy+e7tz6l2And3QZOXXRl7DCS6dSzQ+Rt5qfzmdAf6494d1GGn9GtHhoFCGrzevH7DYWYSh0WPQbDwISTgjsd/RUc2Go/PVoVRGj91o/rb3+t1LDkPfPTo3Mxd43eYRdzSHrq4+WgTmHxilOWZbX5OV5CyxF5yOtMSbizjSKmTON+Ny/2FfdZQxVz7sOQieyeP0deFSSWbnz+Wmf1feKtmHtjT19nTvmY6hkHqlJnF0d/0E/AKIrxJnFjIPFZCa0M/AqsIbYBgl4NtlRXFAYSYCaKfiEwE0fcyIUsl5ZKjcLCjKGKkA+jVEDpJQDKCKtlATd2h8AzxlRSxj31Inog+nRTNRydTn+99uBL8nISfPbm+5fFfn+h9Jy4hocgahgcnt6/vPnxh2Kvg5bL9Jv3h/oASXfNoOVG/9/tjBqNjFK5CfqPrFJ2BOc+TiZGPbKSM6E0WfCZUqVYAx2Fbu42CD+TuGPBilJkcFjVaKSnSvLHJM0Kl81Rd4bTThF5iavp58xGDXJ5LMWqDVKEY2K0GacEcMPMCY7UfmNqHHr9DzCPzqQCaLyw3qiqTahWc5Dh3BQy8H8K9FMKLpr3mZU1ElCHOMF4qLDSL00U6oCC1VORauWGYa8PB/XtDxNKplcbNIGELYoMms76ouos/8s5vDAqQCFTBZBfeTZQfoyITYv/tbgaVzYrjebhXjXLsEdrJHkaQ7FgHJ03E0C2NRnwzEpajwYJ2SnBEIqGHtN7CHCZKmzd+xXOiqDsRbJqQlwvGzznSvPzAbDT0vSZk4OK3ReQ83mlQAiEJqxWyPXpGF2WQi7Rb884TKPGrww6lUFo4Kjj3EX0KwnXeO94OzNTQLR8FENKpQwwTXH9fOqAn7IzH7jyMuh7FQ+WivllW5lOf0H3Anq92DbzW9nLVJ/EXAmzu/WMSdxOf/UspzzYDKBGDTYOnA/roWg1W25qE8DIPFGQOSd6pzrFDtz6UJVG4oinw0aDoz9q5aIA9gR7R5yE13nzh7WHn2zcfbV75dtkWEKtodCLf/3qa+QKA1YUq31CHvT+IIgpoCiD59W5NxDI/o2NO1e6dy6BKyLyT4YXVjIHrfPIoAtBxhnADlHk0oWtzuWLIIqtfg9ay4vXqVswfHSUJ6d2BUQBpsGzF6Ck5exODqOVlRTuYsRcpE3I4Vm8ymjlcqu/o/N46c31i3cBH5Ic0a6+1n33c31c4LWPClHdciWmb+PsF+K5AtkFFa4UJnQxIoJJg14LEv4ONNOhBUeeSu4ls1Bo69IwZiBZZSK0jK3jcoMsiFpCPUvGBL9B7h/bUQaxNo9BkPFZ4FgWq8thh1t6yJJU2rWlsgIBBAjvKgQRQJCtKKSAQrYK4Qqgl3IqRgw5DNlJ0haFxREzazf/cCfiMGCMqBKHq4YztwYhOYIim74DAgTUx3/GmmfCeavg7gPytZ2+hPKYQWDiwKEjU7FJrYaHwtiH5XKpATXVXQ6+86WgjDukvlgOXqbCKSiddjnrUOnpkR1o25/2s2NhV8hpDzMO4ILhvNMHbpcewcOh1hWrpH9ymKU2pVWCiCr5gRgMNqgCMfBoi4zE3vfWDAJUynZueXgkb8yb2kDN+RPG3iFVr4FgBUXS5p7S1wzfh/AtvuCPg7mft2Z9rpdjrbgvqJuS2CtUJEtFfLVw+rvhfPIM6+PMZpF/RRdxQTARED12momEiUuf3Zx5oImK3MNHDsD1bEIEhOpXQWzqK0sYLZDuaURuqe/aXve9O+tffda59D15MBtoKWif6PzwVufrv5AhuXPh3sYPP4R0mRkjTM0+6vKrP3JoL4xg/8E9vwuRAWBAypZCypAKIMxzwm4NJ1arP9PDbZ9yFgJ1sWCnuQv8a+zI1MGC/iht5F4WrDnWEclOqTFxcTxlmPDUjghwns2QoVN95EdmL/lh2siSi53cTmMWG012XdO1lcqEkxhBu6TPwdvPzPCati8sSgpTnEPeOMpGgmExi5XR/pfgfdnlMsM3IIIfYI5U5viINKGMm1LpN9r2PgiFquWY4GEx+TWO+E9ei0/dUN4gSjQSg7wgyEZQSTFhGRnFwkxYhIj8j6PezngxCnUT8oSj2QsyFQgyIKQvn6xD+I6s5CrUDugQSViIAwfkQvvd1uYeWY3FYp0SYMi1Vkttm6MResiJb8qVzKsHOGX5gQhqNVYRQ+csSQ5Du7bzJ+H67NJAmyS+qatL4d6NlZUyxgmxcVb04eDKG/4P3HQvgTQM5mGRac4M3rF8NhzcplO3jYfCbDty1poVpNUMWxk1rKEh6zhqSsNPBeU2iFs7N4eJU2ThHJBIP1JH78bmw7Jk9gvJs9QvoyOlXUj8xFI2r2iVqy1hqQR53cTxcYdQYUKXeTKMjLg2laJs5j7vtQtgDzeyHNkqtoJspK9A2+FntG0imoZ8uBa8Kj7S9cjAcTxpxtwcQcvalzy2wcusu73NVmtwANW1iwq7oNLMCr6s1phtNnzTbQjKu+A7kdAGmDCGyiQIUXEwerUgBxfAUrGBCaumi9k/jmX/d57/Hcr+ppDNt4Yyw8+A1Vc0lnaGRmKvYUj7Dh6e2nNkikclykdKK9B+Md3bxHTLCQ4qxwVnqya+9eLYgbEXAIjL/4d/hvRfao4HYlIkym4YXBfzyOEbbQuox/Y2kF2M8fyXn0VWNsoqMn+YCdc6KsAZ7KLlyRK2iVx+balRCwINQF/fJzxhcRvFafdRXvLM07FLUUrWpc9MOtnoE2ftQe/I7kf3OnfuA+7Q7atr989R+CRFhWkrDU5fyNe6YlHrjkAM2U1jJczEZGA2Rv5Y5Vb8r5On2PXwrfN6PpPOh2f1AFCFW7ZQahRmytWZQn2xmIKMGCZEqrjGF8ulmZx4OywGCyW9FjAwWLR9dEhRB79Yny2VUILEd7nF4OW50kJQDzFt5wIoWRBNLjZnpBJIkMLlaqUemOgTpTpefJXZsEAG/YXRDiMfkeoEUWrRLuLD1vCjJSS94FKQlhCAlhNcql4oNfY1ZzxKjBdGZ7x2FVR3Hz3CkMyPuldWNU8qECWQGzLb5udm2jhtePwe1Lq19JN2qXPmdOf2fUh394kWmmUcCgn5DY48MPzczO5dtCApnw3e3BWDYU1n1DHSbnBX4C9oWGAL5OxQ2y3OLiXx/PyvMojVCrbgGRzyfouMNA8r7f121Bse2rHL207/ABuuv37KXpd66Y8BYWEbRyDhg8Wi38+o9MEACtmVx5BtafUdWiMr65epbOTGxXGZLRfrYJo/gofksMKpAjWx/LVPkPlyUFN5nOG64xjaWvBSMyAnzHlInfhSxptfBnF2ThyjpfpCxlsUtA+ZYXHHN2vlGNhsOrfzgbg+rWOryAQ2JHbVYW6SRcgjh/erRkZb/tgsbBjENl8Wu4ssg4PHK3M5qvZp0JgCZwRZJLNjC3BiRGEic1nIV9N27GkU2GeapfJcAaxoQS0VnbF0OgfvUtzTkI3aMYQWyVqwXF6x48Jp3fEsi7d4UaR2yK3F/wAUmH4YYGncDgJogpjNwezDBbxrx28wQst4NrSTU+zO5njW7N+0C/81e1gMbz+4eGQPQ/BIheiaM5Nx/B49/RVgYqDKGxFu/tq9+kr33e82foQAtY3bjzffvS29LhA7+uaFzuWL4BZ5JzYCyqH04dbYQ0dclF+/IpNBrcJ0YVA/zkH7p0fnXBVLQiO2E5MZxh3lX+Bwlpstl4Bs4QJgebG3kpHricagz7VndLL74LIz3SLEgmlmGsyR2D35eQyBKuN+43vN+0fP2jp9EBEwbJDPOGYr3fgOczB98nnn7iWxLp3V72Ko/Fx1trlE15Bmg1B9iSXeRyolWIYtku61B2foGlTd7V65271w2zUtTFacPIDstUoSFcO4SeJMHaRzARea4KALhX0ICV94bmzP78YP7C38frhQEMIL2wqDclnwDwG6RgU18DRdgamBuBKqE+TGRgl9v6lemiu8BbEUljeuRrnaKeLPRRM5tADXgSylZnwn+x+mX1C9GbD8PmD3YBN4Ce30WKOEah3wdPYjY4X/LyRfTlEG5v9t7tq72yiy/P/+FD19YC05asd2HjPorJYTEgeym8Q5cTKPtY2ObMmOwJaEHnkgtCfAQAIkJDCQQBIIYTLAwOIwwEDIg5yzH2XH8uOv+Qpb91HVVdXVLcUwu7uzxHZ317vqvure3wVoA8z4G7OVkLguPF+uDT8p/tkLQjeIV9XZZ3JPgMy8byIVkSSon6MzttBAzh9z1aUaeqxYukfoFB5+QTR3ew+a60YekXAftkyS8Z4HWbbUc5PbotVfz6199kb3zoU+ZBNYPOlMJU6+PQCxlppIPbZjp/pYl5cjMvUvcrwFRmY21e8koUP6dfMNAZ04Sr4MmXFEN3OAiYyzJn5zQYUzzz88Pnl0/xEjDxBKTVmoBLwAoArxV4kWw0frRqmYLwCvB7UGwdjhH8G1OyoDAflIOMWPGAnXKbAM9FILJXUZ6M/tz5wpmh6IGhUfpS0Y+YHo9zCtTsFTkZWIxosCgUt3BebPxaMX5nTFTVvi+69X37ulGN610wTl4oxbVHua61GFXqNCVGOCBKtDUrsnGnNVQVjJkpAG56SVS/PJMi/W9bD3pJXrme1Ppvdj6z/VBenaIQ1gaMqIy/aHTm/ubH/hfYI43XH5/rC8SsFkWSiBSVC2Y/Gv/DT2XkJbbBVn69wgzu0UDVUmizzXpPaUssfi0iSDKGsVRDPb8otfOHZrHEkBDnf0kO6A5gb07JW+L1I/T4daB3a0javfMVbl/xbuT2U9jcx++CZp/iNWLLA/ywMSNRBRTjct/kShEdfp2DbgBzjWeSQie+hdNey+beGtJzedkR0rOIWuGuZGRGdupPM5vy+DVn/NRIy4zh0dt4mSGKNQYShvBwdlIiHTrXU/C7pZxosgkPVjrHxImDjpFJQRIkV5QYg5i1rCTkpfr3mY23s1dPjOeNpRUIdMMaN4Hw8IOOCWo0fd8EUKH9lMS3U4m+gTbRxce9A9j23CMqYfYu/IJMZg5hX75cWPuzeZrSqQOvLbI82RoV0RIAxwFM5eUvkQvNHHMAJkzKNaVm6/vnL7tGTEDs26r34Bc6dOffzF6tUHgLN15ffcQbm5f9beEYsnn2FT1IqydZ7o0BVjE7F/cQdE9/dwCYNO8dHgWDIZogv+M8rg1NBwX9t5J1T4FN2Z58Ubos0pdzA3We1pPUhWU2Z6XtQrL63d+4NCkuteuNW9FuZd3jj9mje6w+NkzT98x6YWSzjrkfIgTjwLF1H9FkExDiVLzX+Szf101S2rp9t3eQsvUzvLCDK8s6f06kDa6DdBxtjHxvQdwYea84jycQ6rS/LUdgBqDoUl027hFdtMyWWF614Sxer8OwGjAhEWKmCxUFduE3knvHbCfZYbXVtmFdbFb0bYxlBA2g+UFG59+ce1+8vd5SuIG3lXbC0tBzEDoeV6JGBigZ9G76XaNL5OerOZlyLpk8RRaxyrNrX8SWgqAflAuzXj9gMppjP+rOzOQNua5Q5k8BlQ3lnxw5wUdKEoRur1Gu/AFJgc6zMDbbm0HWcuIdqpWh6hpGxY5j7iv4zEQzEF9S2Hvz9ktqIe/vlh9XGfhmEO+rcqs5g8LhzYwJOcOlZtodeYOCdNPEo5xJFQR4Kf6pKEFmbK846LOVHZzX/mhgLxP7EVqGwnOzIyXdk1Nye4w9wpzEnVCHUwiT8+76/eutC9+eew2N/vnWWffICdvfzdxuVvIazW4csfXj3lPBwQ/PLLsZFeRneizqLejSvvAGY7QrJ5o/99+g+isNf9CuBdQbKg5+IJYqVEwEWoSSE2WQ266azb4VCn3CTIEOcQPMfRqINnWGvxRLVKCcGWypXpykQFztku5HfwtI1d7hyLWQaP3/MU0Fd8jsHZ0LfTjj0mFtiVWmy6YuUWgwdmcjFpCtZFaN+VcGy6YmccU1KLjMh1cgbbn9L0ASVbl6+zBwMJXIEEIs1m2LTvvyZ4dIlRrzNXNIWow4aCEIW0Gtf3lv9L6vHs1MjozNRI8NjMC2Pix7aZtHgS7KBHPufoNnCjpBEOmsiLVW6F0bNshhdrmPHojVi1pUINnLa4KvZs9LMSukj6FYhC3pC3c8TbwkWl0FAoC3mSx3UCw1+M1mQksT8yJs57IP7d8Zgfgtwi1jLl0mIYEnw+oPDDgdgKUVNQ1zpl9MlxR+GmrwCA++JYomTgp7U7AfhTZ9+O6cfq0bqfUk0ocdDxPWhfvbg+k4SnnsoeOIDIdfhbgP9iBoo3up+85GlTEZ7fYmmxAM5TKXPl0C4dWMtJXU97j3qj27ePkDdjkaZvxMpADzOIVUMCxzY+6IgZayNyBjr8YLuUzxjeaqxBX1tjUY3lG/F1sBAXaUtwqDZoG2tIbtqm0TXOP6wGJolU/F4c6IMtca0utiTIk0o+mZsHBcmX84BdcLC+LdCIoE2YWan8fKm4Bz5EIotFOmIt/Xjq5PDudjimZwjmByV9g1b5kwi5CyaNWquZA9d53yJcYpbvne5evAXwOR//fn35huSzRLvcXFbpLRJdLrRHSyFcnD8CQlE945E1nJcAmE1ArIga65Gjh5yeg3y1YngOsqkA7roOVpt7wa3a8v6S1ft+iBWIT3ISmxBUCD/r2mbGxxBgCTf38jZQE/Gi29ulJbispTjajKp8GozIMQmQ7OOoqGZ6oFft4TgdDTC3UMAg0VWjg5Rh2K3wql5MD73qkwr0HWRhyjsKic2iCRbSruPo0w89ERXJrLlwKEzJbFIfDtVtdNekX2VDw1tl238VuHR7NLMN3FW1SjGfX1Nv5l9ALk33I5gKOePCre6NLyx59G+nXxQHePUyMx8yElkSqo7xamWfsreXPXfxmgJOgDYnOGHm6EIlgn/+LHu2WV1YWEwgM6YJIumQ4vqB5hSmsbczLbHvP5kgnmuVS6BQOeixO9MS1gtAIUBbpAvRyP/pgelFUPpVVDjUtrq4CBZq960vy2DGFVGfhpQH761+fWP12mvKqsn2q5tnVu5qQWabtTWaXdLN3Q93+7wp2aeXOY9uVkM+oIWmU/j2nXcw44UxM2A1NoWp1SsvdV+8pjNpMnCaAgeZ6GiOMHhZDyrBlwqQLHpZkJycTDsxbAGJy0cWe0DUbXVybLYu+wqOL8PAC4q882W+SxChV6YfluEnkRgUbji5qEuncCtH/TXbHVPxw9YhysbwpBYPpR+1zJDM8jnAKRinLS/OGGQgUxolj8c1fgUtgn9r/rJKAdLfkB+I6c/gOL6IBwPpTnQ3iWTffUxhDaXIe1e0OIX9mHEDqSKYAAmdILZyYq1Ec3rsbFEmOtl/ldJRehV6Xlut/qGJjvdf33vgvCnEYvLFBJNTWsOJltZL19mKHn8sg2n9hMZdAkgl1PaX0k/bJpnUdHFL+tgjfkZvhy3DzIKLxJLdtSktZ3oowP/3RI3tsU4W/00LZcdZN3DVmNHEUDRkJj+lD9CkVlXe0OogfLLM1gaZ6sBQmyPNOjQvnEuhd5mtqWphe1vqXFFi+ET0cq2PEEJBAo8oKzqqFHMtMbhhcimWjwMQpqw84+3UXEPMwUMgdvgANXeoLDsiZq9NFcLv/kCMHMA41qEVVa8txpKqZoR7QdNN4oSvo//BHs5G82Yok9j1P3kemg3pUzE1ynSoAY5Y27iPCnEgVjGoPGY87BnaN3VK8L7hTdebti6CJMrBJQaFDVPWq4AkijzAFF0eQ80ILRy6O5UdHZmhRPQ/vkIMfbDjyauPNjVifESzNNjxnSRec+BLW7iheKGH/nxCwZ5Hnz7/0d8Fjy4Fjxa9R5/KPnqA2fcw9gw/kBRbq3ZGI+6N1tISAIjknMwE7G6+ukFdfe+W8m/zQ7YgpACeSd6EJgcAdJ8v3uie/4Y2uyOJCyCB/+cNuXfa3FPMHkq961irocQpEjHFh4Ogb139cOP06UHoWIwUSx0cRLf8j3D+VbyWxnQAKEKQmZS8fORrFrmXkcJqmqJ96aLlcuQSfrYPFQ1b0SF+wnpIiQoQLFoDSohVrZyVgNHHriLZEOSsRul8dl1J1om4qXM3gWTNT9CCjOpiuok3AzbsrstfQS9J8f3gfOEbVruODedmVqRd6Yc9CEu7eyi1Md2sFaOgOcuTIKlPU7yw6VIt44UtJZIjnGyeVAYNOt7MaG2AyRRqzcCCs3UYSL682X39+vrL9zkZ4p7SbLlQQUv80dlWpdmipDKHjmiOsKC7yMpBWanCv+KTbJZCk7JZrDw4AM4vhQquHw1LHXI5Sms4pxQEQ+yA5XjN9A/QpVLlOLS0Z/yJfbsO5vcenjh4ZPzgnlylWtEcCHEvaX1nvz+C1SBEAvoTFOSgUjoR1J5daFj4GjzkPeJVNjtBt1zZbI7hagI4fWKQ4dwkfVhdLNL8LNQLxZIfi8RndNrqXKT7Zm0y7+Y3d9fuXl+/f2vl7nfdc6+w2UP6dYX8D91+/a2i1a310my12gwgsqwMVl+nndaofvXCxbWbd2gzCaW7e/GWcunpXjy7cRpisAS7Jk8PDxL+edSIrnycLFSEuJefq7Xyi6XjpcWU+A1SaimXmjqGrExB/sb5xcJCI4QXAdcafISYSaXh+TIk0lsUMu7T+Hi6MZQV/6WGt6RRjKeKIYJw+AB72VDxHJC6Ydw5DSKQqSFsOE1uOHWZQQyTSOqnsO3PnRzdiWguhWPz+cUlHzMC1eYquHq1ShnRPhql7flR9dsY/dYobfM7cOmOnYiowKN0Q7iN0owfR9Ay8QMLzy6VR/kn/j0/unMOfy6hDCW2xizujZMAHOsbuvQ2tOpuU+2iYC8amMWuLz4PPe94/8QvcdRj0jIiulxv5iGleP7ZUr1SQnzTpqCeGm3SrB3FgBhOcLxc580M3wtFsVQ3LR+aySPJzuGiaGtv3up+/DInNVh+sHL7LiTHfvWV1Y9uMwT7tc84fSm/FEIM5/t54onDx7fpm3F2tp7n1LIxZhCcQz41YpRbxd4VDHFrc66WF4W3cmE//TPe0oAWYBD7Jahuvuo7EwDTAshPYJb3wr+yYwQnD331E+A5QjAxC4nCNh/BhLltBRyqgWeflgMwxIW8Kk7tkpidxVKhAUhJTIu4fxD/pq+BUaVYLswg/MFlqQ+0ZTEU8AlMHaOaAMRg+UMl6ctNyfa3Cpz22vHtwzAVYktCnBJYRXk3y0/g4A+z4Tf/XLHcmPN13yAcO9aJPqIon1SqJ2RIUaNRXqhI9MEpoao+WzrVybXxyrXjU+bc0in2LAAKJoYHFv4j+w4+qVLmKl9AVX3WFSYRVg8jHaReDWa8waAymKFm9LW2lzfsjt2PmXhvfmtOEYlwSBt1Oj5cAVv43eTuI/tFQcBkwYB9vSxkUcK7DXQHi7v3i5gUE7J099H50GNcPwrRWycH2/5Zh2cwRsqkmg+vfORBoxe4+kIek9g0/HQYwMVgTKmYd8PA4BeEpp/yh+hj3mvkiw5qqQ/hyI3Hs1u3Fkuz08PUn+nhan0hJR6+MN144ZG0P2BjenIjWdMnOWoUDy1S8/7TgktDG40tw0Nt6gDcCfYyaDMnd1JBlZ/VwBvtZzL4hY3N2CgpVaUuHYHqYhFF13EleyKjZh1wPtoUHD28rwHSijED3CgPVDM/h+a8p8cZqkuUrVTFP4/Y5bwX4Mc+V3iANVdGki3m+cVinndivVSrNsoYdAbMmbw258SQQ2xbQjjSZlk8EMRbyK1aQBlVNyyYoa9tZLOctTrR0rhlJQb/fMMsDY8ALRxqcBWG9/6mwuuogsDHeLrmUi2cUzFS3N8ylk68xCg6zAhwvDQs3vtaYPuJClyipOiMwRFb5AMG52urXiijqs54v9118MDEnvy/jf8uP/nUrrEdO3XLaLMg2pbfRq/rwuVDy6k4b94UtJMrLBV3bveAOJWKweypHHKSGU/2rM2NThze9+S+gx2vLRe/gzZ/6YpYK1cqnOPSP8SxTBCh1TrJkzbEf5WXxKtgyHrKsBDhc7eLY7mSlRTK6td0RbwMDtXL4nXzVNbbAY5K7kpk74awTL8VjkK4+4AZrSRhcjBCCdksogVlPNw3EHpEs6IAseAV7e2MtiDh63TEPxfpioUpZ93/aF9QJIoefZKO/VYlnNqxIx1PrSNkKxr79IucnIhsPxnsKXEZBOxfPAcGh98WKgeqRY+yFgsZUdTfYdgKhKIi5FSJ1TEQH5XniKxSeESJcgQqmkTIJFo8FLdVVBnflUJFVcOcpUxMhAWtb3lC+Qz/DhabEb5yvFAvF2gL1QHunCoXHc54wWhkpVVMuN+mRjvByZ3bj7e5lo5vQ7+wJV5aFeYKQrRBFbEg5NkqMS6+UTckxHg8abJW9wUQPVddbC1VSEAFLE+V62ZeonsisGiIGeq/IDo0lp5x4cYBFgFXiOF2BDHDTwBNAv5s1ReppvC5tBdAouBh0F0R3FBUYBx3d8weM0Qx2zxLQsKWNY/O8GxH1VLe0d3l91Yv/UBGmNU7F1duf0nuGhsAUn+WYfPRkgJgLLsPHUVUNdSVlOXGdB8klwjaTJoBjdRtvDubI0RnOZ85MZ+jaWMBWXktNee2VhsBK2IxCqsCJLSBQiKrIyQM6df19NSu4N/zM1ugbUSXTpudBP6SlQ7VuCEG/enBwbRDJaIyUhnqsEWI2A9Ybeg13pz8evzw5L6Jg/ndE3vGIXOVdpcEvk5K81wSJ0B0isiWf/JXO/M7t6Pfol7Zvj2Cw3NK0TawSnG40NaGZlK/Y4OcuLzbCsHzCM04EjwWzCAgL3c82U9a7h3cBuxI+s6t1XMv0m4S+4iyNiCODxlwt0rzLXHyXx+aNGx8ADxaMyj21PbsDoTtnvWnT46MkvZX0zYHWDbmy/WlE4JTbBUCEPwnSExDicmTpTlBKiBeIhjykwfEt1hocVm586p3dHzvPo/Ke1ABkfruK2cpjplsNDxkjGb2jCkxhsZ2EUHKns23GuAf5G+dxUykw/P1Usn7Z0/ISAq0ZMgbS+oolvR4dv98Z+Pyt4JHrX/3DdZxAHN4UUc3zry++s6P9IkGmSctmGJjRoyaPK+gkW5lO2SyjYjrJKYEBHQmao1iCaGXoqjYY5+ivGbsSbLLk0O3jNHORbmkGn304rF75tXuzTPshCWNQ6pkJyY1Ig6tvqR8DqRFP813BGSttGFyDWO6ZfgXfzJRDQCWFXDqiw0VQMlNGWH9qpM9nZo2H1Wvq6z1Epi4xGKaipYhz/VCJw6NFlocsRyHySkEk2THEZCCxK4so4UBJ7JYe3YheK5VquMlT/Ab/Hc+90h7D37c6MQJE07TIh3hJeqNrtBOz+p6Qgq9hIGjECkd3vIf+WBmSxpdhsM+Gs5tWHJ4oV5t1VKjuDmondBbmfgpua2CHW8bMFMM6OPLKjJvG+HeSdZv/UrAqAGFEsOiiXeI26xbVs2UqAx91iLKlNHkAYGWa0+l4AZ/r7vvCeq58d717tnLa8uXV795F2Kt5p+LjROR6BpF2dWcS8AYCO9eK+DM7iiW86Jm3dhxDyQOOTSiJto9dQuzSgyt+OPqhYsrP14FUeqVe93lH5i+tO2Og45hTWOcO3B5PjLsrDN1JtRkErVIqxE3DMnxV26/CcvqUWJ2lUK1zys1CpVmVw4aFgEiGI5+gpgvYqBOqc4pZpUxEXJ2cXC/M1tBjM+qL+ocptI97nEUz9ab0vwjuV8NZ+syC0oAqPn+fvyWOoKyYrQjDmt3OO+clti4Mkw9nn36hWw6JaMSdnTS040t06nJpiC8S9NpFGa5i2yPc+wU4r5qCI1j5BR/ZFNdepoa5MyI0JvJLVm9g3iriS3qPdLro58IIaxXDI9Ffb3rkkYIMwNXLAYlZbKfEHR5cvIpj9Lb09UcpAfDlFYGICV+hWgRpP1HELiardpiKdUQzQsW2IbjAl0hVQFzBEJ2BuhcCLAGm1z8LFUaJcOEIY2bu/btH3ti10FpK3ymAAIkGgkfeyyQmFdi4ciVy9dqnS1U8uQIot13mldzlfmmr3l9w5+c6QNv3mSWqATu2MvLG+rEaqYAKTq3JJTxMszAjO/ukcpNpXVLz1clM0jJ5FA/pWuyXnfX4lQDSiJHGwixWj05RHRNkZWKjbNXrNXYE+Cygl+Ti3/3qxfXPjHIHPEMbR9ILOiG6cIf3SkD1r1a1NYVvc0wY6A2QUEhccKY2FvDDJzQJx2VY4oivfQUChPurgyzWSPBbobhsGTwpfuC6GU5zIAcXECYXTj0pokEYHOCpLIG8oPyztKnIgq4YKZSca6LM4BpUwujpLpwetT1SjyGSzSjZLRxY856jzhuBum2nhmmnMnNXaRa+HjRPvSlnfRlxw2vZhMNuZvbTTH3veR/zetoVsieqqiEUiqftJY1h/XQKDJPOnkbDHG1vbeepdrZYao66RvK6Jh6hkYjhQSXWGiqCOCWAclsTdZiz2g6PWDIQLvxl0MFob/WKfVNrbpYCF13FcOK0GHX9QNVS0i60RIAf+CKd5JpdqnwsUIjLz28eP9HGgAzifUNfgKCgsrRNkVvZgb01EWgkqKzCEglQrTJ7xnfO35wchx+7jq6/4jy6tDabNXrDHANcggYH42aoimGXPtbxkO0fbEa4JsLaPPEF8HR/90HSFCE+CffUZTr2ueXhUBGtwEnBTETir14R7jo4Bf+7ld+B5MEmfZ4yBIEQeOr734Ln6h8QaDgqYrYJZ0xHbbtHBn52+kXR0eWkKWPbT/mW+RZjAy3GcIwQoY9CsKg9GsQu9CGZgFYfarNk9aZ8WJy5QiaIeojJ4apUbAfoJw7khnrJHbX+vpXnanG0rHiiZnHffsSTHZYu5EPjb/cfEZ+le7rWoxGClcAFJjsTswR3TiyK2IT8kP1IewpWkDYuNpLmbhDnW/QEBJtPMXZ7CRyjoB+dNC9kRItBezu5yfmzO7f2wwt86pvBvxAL4NkT4sfuwBrOJ2SijkHFIrbfgSeVfUwgXvpVGDiNwcRlEKVi0E0QErALujMUXI+oP6AfU1Q55yfYZciQKcRc0aPG+m0Vr5RajIJAZBSRMdEns8DCzOVipGTTuPLCw8onzX3kPbVDDMMXRkix6FWs0aJpZrg8rFvIqWzg2GaD/pItyrpvIreAhVErT6EDk9H4TlefR+C99tRThBGl5SK5aZRf1/iv37v/hB4duxSyvhroNhuvPd198cbZJhZu3dp/ce3bCUXOlitY0JWQ4ksVKoUA2Q+P142mRoV76NraJLyoFokv8fLVmz4QzjAANtzub+ILb2ABNxwftH1aPNL2g+sVkXULPNA0zgzXDJthYToC8x1m1UZ+a5/7u1gAJPT9W50D9jrblli4Ygps1eSyN6fUR2ZUMmOn/1XEF9AykOX+Kmnp+vTlZkhMGth8zINfYHYMAxZ1gPJrlH4E8IJP5sanQkhpjy6apUXCRkhB3qBkEWk9UsmuymdBK6IYYZ4JUmox2Lu1e2jbpsZrivvRNw/aTwQUDCc+2Fk5L8IUbIaAd3VUh7HsOJUjNUn9PrDAmH4ZoRuu0BRabLkn3J4jqD5CFdqkPYh2ZLGgtxOGJz8LzTgHS4tHfdS05N4EWK4ZEhfQczbrCp25XDUOuToSvrhNTkExY1MXD+l+BQp+47KBJeI4Bc9/6FaEcJBrH16d+P9m/JQ0lEEtLEHH6y9+z7ES4oTqxpWfhfdt891X/lu5e4lcYJXX7+pn+ComdEMXJS2wU0pT1YgI4Vh+tHLD9VjCMGUtw6Dxk0FB112v7qCmM4UH+uIApUzo5EqrpWQVwd76WhGQ1ym48dE+WmSl1JY9Tg/txarq7CuoEi9tRjZrAd3lBOq3wFZi0FkuLeBy21isWpbrC7odYmXikbtn3gyzv8Om2yKJlVaBX/biIry0GtIMrBgLc9UW0CupAd8K8biZbYyr4TqmuC09ZixAcPWxhaVw1yBbw7+zEcN3ExDZg3WBGAh9QX8fXhXfQHTLbGdoaih4ubzxepcPp/WSqJ6X+AiKZ9PrhhVRTxs5PzHfaV75/Rr/2NVyBmdmwpBkLSNjIkIzJV/rlVtYixWs16Yny/PBTKlLzwTZHoWs1yDfiHk2wYFkBGGGj8LGi1R7qQWTxlqVz5cWYfifCA/wA0X8PQRXS8InnwqOF6WwT9Ciw77XSwXFirVhlF1nvsRQJ45+Eg9mFusUq35Y9BsvVwIKgVpz87DjqHfMNMu/ibTPBv1ywlplhFCNHyAsWrwAOcuWGgV6kV/JmHxgqBYXaJU6cdKi7Wcj2Fe1693L573E4tBprlFVWp/qTnY8MYrc/VTtaa38dLy2vJfksuTEkkbPgcGQEGtWEGjKjEL3eWNKxfAww+vvboXXid+Qv5FdFvfPX0vuaFavYpJQMMNmPKVowrZq+daov0lCIagpilf6vrrL6299IPEIfxh9cbZng01q3PVxYYawvqZzzdOv9Y9f2F9ebl750L3wvchROfgqDfmbfO2DyZXam5jqrZ77bO1q9+uP/iQYvKufdU9d6d78c31B/e7r3+0eulM98vLf793FQFWuhc+X33vx7Wbd+ir5LYMQG1jvjRqLGEBNARbGXWeaLmI/T8OmbeQJsMQ84wKF8+YaAKbbS8EE8hEIAHS/UwQoh0AWAXc0CGyrVpuhZ9M0cKQ7RNBnsW6S4y8vtYAjYzqJCAgiQ66BY6LUSCSq9J0ypGcZ86tvv8ZODss//Vh25dLyx1AUyeNhOBVIKvf2UuEB0hvqROEDchNCAqL93+qoaVWsyVI2al86eTcYqsBwD/kYaS+j/RHPAvU7kuiFtf/tHbtDT1UUlAL9AUhFw4/uQlF/ROaWLn7puf2SmYaISaEYsQ1n5nk2QZW4zpuLLKaRrbwEKLcYwh/GRYYQj1EXiSU6s2HWgQoEOnnidJsHVxC1VTQBsMgBO83pVl2QOi+jy61kBIzGBn11q4ud++/6yfUCw8DUEBD2nbzPNR84RZt97W7X65euw6V7hafzgqpdP3Wiys/fLJx44fkmQ3ZZih3+PLQC3FFTIE/o4kpdPr7qbEYPC80pJDGf/Lq2tVLnnorTtmf1r54H0jy9evJNWK2x2BhNqwL5X4AiLn3kVCeVm6/IdS37sWz68s3xMON9yETaff8uyv3z3tPoi/tiLd+4zNB3Vdun6fkrMkNCiUXddWETb5x+sr6gzMeig9e9637K3dvrt5+ZePqd6AFvvMZJRDvsakFcyUX0JBAqr29I+ONiv+2jSAmlTq9Wl5yIjPJTUjhaUzQ4lqAlls1gqfkO2/9+2/Wv3/ZO7rnkEcCxPq5l7tXvw158Nj2kZGRQPw7ukNQzwrgjPZDI83WNaEUx0toLeJNXr6JZ1TuHiuWQWu99unbqsvdq3e6y1fE9IERkmQjMZ/B9h399rhVC5Zmaw2rs/waDNLFE+Vi81j/Xe4uf7x69nsxv7RtvQOidm1n0jHut3cQ0/eP6x+cpsT+YfBEuYIRNYcmDh/JHzo8cWRi98T+Sd0xJDqGeTGINhTs4F6UW3Hebx+c2DOeh1CKSbyXhG8y3iDmDB5Md3hbcuthngNuA39AK3pqWf5qOEQNAJue/pR4GdnY5HN52Y7J7kHxiQyoRPq8znExv7HOH72Vu69gBMKbwEi3GWEEsiVQPqWtwkoC5uqMrmzF9ynkk1oXtKLOnujNMH/HboD9k6NjtA5SHBnFzDyUYKlWhJ2WJfKW9ZiBuKyniCn1cHKsVQOekHQ6bu5YIkF/2HDqqKwxa+5hmFBgeKuYcg1Mn8rYvhB703OfEO5N9+I5ECnPnQHSZuf1kY3zZtRF8H76T8FHUsOwpP2Oc0B22pke49HlchqPPRKosN+5tvURVwcJjPNhe0g7wd1DrNF5iED/zJP+6faTchw4FfSlCa+6HtuxPZzMw659qp12rgsv37QvTON2BGCDSKg2iJRjYBEwjIQcv5EOmwl+tdlgu4NBZDRKrawFfU+rdqPvJ8+gbJqOTNhSZDYjGYX67F3MUBEaTjOtRH02LOL05mfr5y+SbYVVCpRvyGKydvf3QvYlACJIRojGFPqY9i+ZVKLXG5FuKQuPa6gQ9KRzJ30wXMx+H06Ny19PH+HGBx+u3Lm5cudtNgVpVEJfGYdZqCdLk1uBcgPIL5QshRIoeafpuXv6ZzPhVjXrlFJtXwSI5W4Ua20mFNmD/Qz0H8W8wzG2anmQQDOO4YN4ii/j+a0meN7+pLt8/2cbtBAfC01Ba/jjDDlgbfF8XGQ/HZkPfC/IMNwkHj48vicPsuhkOl7IatarzxQqKMH+7fSLQuiqlBYX8U8mJAv12hz93d94UN2MlfzIuh/fHSodtoTfu0VOUjj7kjcjVwkJQidXG3bBLuzsDWr1+YXZn8QuaXJ6MEppP4jhktaEOfkjfsNuHvYAfl62CKM8VmjQHhbb1xcbutQqF8lJp9oY5r/JdW0kVqIJwejAJELWCozhYr8zT0u5Xjvlrb726fqNc+7jBqGIeEqcHoh1P4yY1IMn8wF6Qe4YA/e9SF2x58u0X3Uvnre9EsUUtJYKjWdTI9WRX/4y7QxVtrcOIs7KCyg7ByA9TqV7ZK911RnecGVtt1V6vqla3XU+RJrr8GZeblYke+i+4wafaJxqDJdOlpupbZvpsLxOtD2F8WleCDmtlJGz7yEnmXTSPjKBuyGe/7f0TqfC6UyoHQnIznjjE3vjEmuze8l0BXwvLlxa/e5s7/zE0ZlEytnXXW6nj5mOWSqzXvdWi4Ho1cTMKOwHXvo7G3SaRYyd7fCdcdhgBG1V1wk92g8tSu4WdZxKR01xR1CPENcmww4Td1iwXHssssUS9tXqH86v3L8mdhegxlz6cjO7i8CqQ9W1jy2k4KsjOuf/s0PTy0vBOi+w9KBLQbiP/NLaCBTr03RsBEkz5TVJCr/LOOfb7Jc1aXEHxizUR7CAv3bvTvertyhj2frF+3BBjtrZ+vJX3fvvbnazRPw6IkozCBo4h+jtUWewkVQaDcQHdx3Z9+vx/FOQGOnwvl35vfvG9+9BCYllz3wVyqDYlsJa+HnqyOFde/fu25127BnFBEcTR2QsMP6RSvfkkOi1Y20UQGfHF7TKVjSYk9zZbmF0QI4VhP6Nzn+cbwBD0yPVyngS+X3sqUG7u0feHZDkCqVHskeCBn73j2sXX+1e/Wjj4w+6dz5BLORzVnqr3iRPegS2AWuLQw+QGMhupztCcv1c4SVQqwBcYPTugzMs2/I1P+D5YEej/cBgHMyiI/cetxTfuVBLpYtboaZ7fKnttdXmYziojoNxqIsYcPqGxgjzKVSV1QeCsLQ7aQeVJAQ29d3UYKs2ONPB+xkMMBLykQ+EKmyKwqH4xiZSIyjnkTrhoVkrPHmoeqNzpq6USMX3PL76ardqHfgD75na0JA9dbV69eSpjJfPeLNlJFfid3nipENbKu2GxThzp3vhj2t33wLDrdeWX1MGnRRXzLWm7XbxSEpK4SYbvQ+p8rgz95XqCcrD/Z54ctkza8JnVE0fNVh+eTaCLb7M08uH65ptmKB8JU10uk/Ul3tZARypPiOLI+Vz/rNUCXP0ZagXOfwXPdZLzZxha+lnFRMMIEaassiNvNeWLEgWTVkGGLjQ/PRtG2EyjlGSs6PFOuBZ3wsV+kZmnWLIlK8+mCEFVGI2RCljCEEJAEzlOuZDwFOlWiFrqlj8PH3I/YwGpJpyxwlN6CEMDqw/neH2cvTDZs1iRufKiyU0uZpSUz8zQ/6j9pkQz/qqgsTDZCdTSzqM2bfOzhkV9zMa3Zk1stQ/QTCSYgE57zfKJz1i/eTrIri/2Mt0L8EOMSsPllff+YF8ccDdCz1johzZJXRJcV8HN1NQAVLgz3C8dx/gZ81CncLNCnV6YvQAgIeHyZt+GOSKcWwdEwHbpjsrhAFmgRWnm39Z/xZyWonPEU5ONJeDYTWaRaGpaGm45FDHduzw+llDIoSj4JsuPs+j4Syfp+/y4I2cz/M6k9v6wP8AYuEvVhxNAwA=
__HRULES_BACKEND_END__
