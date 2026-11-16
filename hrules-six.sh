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
    bbr3|system-update|reality-vision|uninstall) run_installer "$@" ;;
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
aa61190928810031a6232ef76cab2e6bebb6b3b2f4421fa1161e10cf17c87bb3
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
__HRULES_BACKEND_END__
