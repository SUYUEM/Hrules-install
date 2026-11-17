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
    printf '%s\n' '用法  sudo bash hrules-six.sh [install|uninstall|landing|node-suffix|status|diagnose|links|quota|traffic-interval|outbound|nodes|shortcut|update|performance|bbr3|system-update|ssh-defense|reality-vision] [选项]'
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

guided_performance() {
    printf '\n%s%s%s\n' "$title_color" '性能基准与调优' "$plain"
    menu_item 1 '按节点测速并保存基准'
    menu_item 2 '按同一节点复测并比较'
    menu_item 3 '设置 TCP BBR / fq'
    menu_item 4 '恢复 TCP 调优前参数'
    menu_item 5 '设置 Hysteria2 上下行'
    menu_item 6 '恢复 Hysteria2 调优前参数'
    menu_item 7 '查看 Windows 客户端测速命令'
    menu_item 0 '返回主菜单'
    local choice
    read -r -p '请选择 [0–7]  ' choice || return 0
    case $choice in
        1) run_installer performance --performance-action baseline ;;
        2) run_installer performance --performance-action compare ;;
        3) run_installer performance --performance-action tcp ;;
        4) run_installer performance --performance-action tcp-restore ;;
        5) run_installer performance --performance-action hysteria ;;
        6) run_installer performance --performance-action hysteria-restore ;;
        7) run_installer performance --performance-action windows ;;
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
    menu_item 20 '性能基准与调优'
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
        read -r -p '请选择 [0–20]  ' choice || return 0
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
            20) guided_performance ;;
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
    bbr3|system-update|reality-vision|uninstall|diagnose|performance) run_installer "$@" ;;
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
6fdc1ec6603d3359cb7cd03a8a16a93470b8500314ffefcc13a592a8b2905b8e
H4sIAAAAAAACCrS9eXsbx5E4/D8/xWTy2xUgAiAOEjx+y3hBEiQhkiAFgKQomotnAAyIEXERMwBJMXwfOxvZlm1FymE7duTYTnzFsSUncWzZ8vE870fZFXj8la/wVvUx03MApLL7Ko6Ememjurq6uqq6qvrHPxpq662hglYfUusdqXlgVBr12IAsy/OtdlXVpVq7amjBZqthNIqNqrS2kpW0um4o1arakpR6SWq2tI5iqJLeLujFltY0tEZd0tVWR22FoJmBAa3WbLQMSWltN5WWrvLngqKr8WHzSasrelHTBsqtRk0qNurFdqul1o1QuW20WwAHK5ertFSltNJoVJP7arFtNFpmDUPdN6pagZdkb2pKXdlWWwGp3q5W2TuzSlmjMLV4pWnyboW8C0jJVqsBg9TZa/JI65bUolZTqrzaDH2k37ZVo6noJsRzqrECj+tKq67VtwP8Mx/49k2tyX9XFL0CIzAfa0rR/G0YzVCxqgFKbK8oomnHWoP3OXVgqHpqOSBljRZ0mlrmdbSmUioBOs3ub+iNOv/d0Gk7TcWoCIhcgUdepFlVjHKjVePPLXM6dbXYUg2zXRiIum89tA2taj41ijuqOQpdtz4YCpsa/KXphlY0sVhTS5pSt0q22kWriXYB6LMojEo/MH8aSqusVU0wDbXWtD0TegIcmS+0mkqBMA6a8J4DkFYAhFy7WVUD0jIhcj7f7VYVsBUihMRL77YbBhRs1/mPVlWtFxsl1VZFJfTFqsznciuEwgLSamZRoDVWuKXutlXdEItnACkttWjMwzqsIsFmaJmAVGhr1VK+0VTrQBysRrutlfjvmwKZ7VHK1AcGppczyfxaMpNNLaelSUnuREKR8VBsWB7Irs4sL6zavoVDI6FoMCIPzG9kc8lMKmH7Gg1FhkNh4WMim03msvDtcECCP7JSK8WH5QlJLhejI2qpXB4fHx4bDY8VC+GwMlwuhyPlWKFYLKnx0dF4PKwUlfBIOBKLFQoRpTQcL8bH4uFYPFqKygHWYKtGG1RHiyPR6HAkOj5eVsdGlIISiajjpVgcHkpjpbGxUqlQGBkdH1eKYTUWK0VHo9HIeCkKD5FYQSlAg0cUFb1g9tFfwWKjBmtFK1RVOSDJ0dF4rDxSGI4Mj0RHy6MFpRwvFUdG1Vh5LFqOKYWReESFgcaGC+XSaDFajsLgIuVRdWQ8qpbVcFz2O0biY7+g7ZKilEfHlHh0OKxEx6AmNDFSKBbK42NlNRaNlOOFEvQaHykWo+Pq6Dj0MhwZj0Tgc7gwEi5j20cDmWRiMZXbyM8vZ3M4S3t7e8BTGu1Suaq01BAMRx5YS/E5BG6qB1vN1n6wo+lA7/LAynIml1/JLOeWp5cXBbxUDnRDbWlKlADdLjXlgB+ANtpa0f6mpqmtNnllFNkrvV1q7NjeMSTUD6B/e9kObEiOV+KzRDrCt/vIG91tGq3GDaXuaKCuVqv2V9utZtEJpLW32Zo9GphJziZWFwEtgBuCEhs2hodjFiLG6BMfBTxZ1TOJ9MzyktlKS6lvq75oGP4EpDj8HfHzNehZcgSLQMmRkVjcP7CUSmZW84spWHppR8FIODpilksvzySd7R1aM+LRoTCH7k6s0cwvr5gNykCz4XAQ/o6MyLYSqTSwhrXEIhSKhSkw6cRSsgdhyfPmg4VSObeampY6I7IAmLyEP6Tc9ApnDeaIZDokLG3Sl5yoH+QWs7IwM/LaYjKbldhykdYo+fPGSIlsRSk19nAr02WB4FjNa8idCZic4uQc/cUbYVQnZ/GH1CGLnNGdo/ftzMq0zCgtmckkZ/KIKUSSjzdvkjFvxD+QWlmL55fTixtCaWeZxeRcYtoqYODm5qvDPifBFi+RH1pdEuZFK9O39YaBX+wA+YG9TC8vLSXTMwKMT93oISLYwtwR0H0WKGVqeTU9k59OrcwnM0hUxYoC/0XDQU01ysFmo3oQiYWBvihVLgGJpVYWk9dS6TksLT7nF5fXebl5IO3sfGIhmV8CgLCk9Sabg5+JzAxsfrlELpmfSWHHKAz55KGO0hqCLXSoQoTkoK7tAz4zq+lcailplULJutooKlV32VQaWl1cTM5AaV5vCAjeLBNqHgCUiXRiLpnxalFHkd3WZHYeVtz0as4OqVUDKkCp1ZUZHE0mubKM482ubqwml4aosB9kkr3MS4EgAoXKMlK3PjE0pDS10LZmVNoF3CyGWmqzoQ8dCk0eDRERu27oAmwhvfJMSy1P1hSAwAIgC5MCrVvYhfHTxoPtZglUiiCKgW09hDKqWW9xeXqhb60QjHbHLD6VmF5YXenfTbOldrQGdKRXzHrT88nphZVlYFH96xYranGn2dDqhlkVZIaePSqgsZijU2FxCLUya6lpQoMW5my9EFlfK6pmFSSaTL8KKMu25IHEam4537cbASyrF7GaV1diJd7TioP6VKMIRGMA3V1LpGGN5ZczqbkUES9KaiG0r9RrjVKo0dqWeYGF5EYeFmB0JI6F1FI0rhZi47FYuFyKjseLpXBstDAWjY4rpWJRVcKR8dECSG9j42oxrKBkWB4ujw6XR5ThSHFUGZUHpqYy+exGdjq3aIcKVISiUQ2VhsbHg2xQhUKrEwuhWgjwknrJXA44Bt0W66oB30BMKqllBZTi/G5J0wm/Lu8iw8LvWrMzHALZIA+NbIMgDtsG/gReRpg9dCAfDcwmUovRqUTajamyolWjBQWXqVlocXnOwXYa22ZBoPVtXPnZ+Twy43Q2mV9eT5OZslGfrleCALZa11W+xtWSbKvHNmY6VmgaZxRhjlRwcGWtXjLfhGtku1X2QeFrHeCrEZlKzHZmVtMqjVrD0gFsX8vm5h48dGoQR1zhsLdHt/Gguo9qC5IbGaNrrAYSJOUZy6uu5SuKcrpM5Xwg8YSzHAc+RwRdqxh8QrnBUmyml9OzqTlnGVNyYZBksfjSjIsGQR8tsX9xIunqzDNciquNwmOtTl40uzrlKCmO0F1+dt1RvAwq5B4QhLtoLpOYnQXxyl7eaCnlslZ0F1+E/ZLtt0LxKuimoF26iwtUIZa3EGfWMFE9lUnNzMGulLXxIl5DHkgncqk1q+X8bCq5OENUGb7E66CudVSrE3mAQe1JAwx2qxAnOFslB83xb/PJxRUCp+f2buIFt3mGaE8uy9HNOCwvymVnvm6h1oj7I9ImDooRH666Q1tnR6GSjIDB/gXYVqqU+w1YM2/DB4eFDpQ35LUj85J0LzbhmllM9igZ1EpVjkFA2yxs3NnkYipNhEhbhabaQguUUi+qQbQhVrW6qos1QfDvse2LVYFLi5UsGju3JiceW5+JzFyS6NRcVNKboOw7tOuhfB6UhvozBTTPTYKCPhwLDyMPSucyy4v5LCCSNGLnJJQW2DYS0glGgbFRiRhlaCK30lLdF7/p3v2j8D23sZJkap2X3kJ+jJAP0HmW6FFclUEdBkBJp5PTOeDvIIZT8ZsoE1SN6SGFo3oFwESiY8HtYo0/wpZOH2ndaDgaDRaqyo4aCzpKOz+ZNe2fzN6tjgf81tBTKx4MADYPtWioJfihGUGtKaBqKgV/uWs02kah0a6XYOMk/wo1gPKB4yyn+9VC2ZuYDewdoVjRrxoI68geYKNJphNTi1yj8hpRXSnAbh6sN0oqFM+mk4uL+cTMDAjYWc8KRA0MMjswqQLMIpkBifwKzHQ+s7qYFKY4tRKcTs1kAuEQ+d/QWICWw8ng3yLuj/bKkXA4FB8mRSJhrwaio+e1EB8PRUdYE3GvJkajoUicfo/2amQcy4z1biQaHWZwDPdoIjocdpUwv8YDExPQe48x4NeI7bPwqVwMh6HyaK+qZXUMv3thDz6WSWWhX/8A6Lo54P+w92RSokllOo1r+8mjz7q/+677/kdnb76ATc0v4NuzD988fvQQn5eW8fn4+7+dvfExPufW8bl79/Pjr7/H5ysr5PsbHxzf/xSfFzKk/jt/glY57Nk5Uub1z7svv9t9+z3S7AYp9qdPj9/+4PSDH5588xZpfJ4U/NvnpLIkrxEQT798uXvnDTLOGdL5nc+733zY/fxbq+IKqXh696/d71/pPvjeRFraKo/FEqtsMDDe7kt/YpXT1xl40F731uf4ajWLr06+/wUDZDpBGnr53eNXfoC6ZATXyKs/fIy1fv0B73KKjL/71RfwmnRJ8fHbH47f/br7+Ct8NTdFgH3lL6zxmSSp8v1X7Hk2Q7HwGntOL5Lyd74iwNFukgRA6OPk7mcnt98kyMmRaj+/SwdHwCZoOfnl77t//DM+Z5P8+dYj0lOKtPLyp2zYK4u05z8IPWUIzp788POT7944fp3QRI6O8f47p8/9rXvrSzLMJBvm6fO/Obv1Cr66TnF2542zt39PzFaUEFM5GxVWG7qE9kjgR6TvL353/Pbtk3dIo7pSl240dJX29scn373Wfe/3/EO5BXsw6F0NSn8fnb34y+5f/kK+qophVFWGoLPf3er+zqSIuronHTRaOwQP33x3QumCv5WKmnFg/1QCgVghoJ1+//3xK7cZCooVrahsNyj63ka6tkig2qiXiHVYfvLth8evkWYQ2p1yG08/axIxf7ApvvV599YrJx/exUJNpaXpjHzOHv+CbJc1FDFKSo2ht/vRCwDBye2vnzz6mvdnNHYOGnQt33/yDVmFDV3ZUUhLsLB/+wnFSqNdpWv79e7nv8FXO22lqkjVdq3ZbpHC926fvfUCWaHMOAkbjwI6lupavxVQa6Ud+MvOLQxFa6oa4xDdV8mi1Q9KdZVg9fhnt2HVknKNFkgxDQrhW4Am+Juetiwur87MLiZA7EFyIdbKaVN04kIJilXuI4uhYqkeLG5rQyBJgraAps9UenbZaii1otXLDbERrYlvQlpjiIhwpjWOi7LyUKstGte4zszEWbRdz6YyyXWo4hQUTc3C0quomDi/vLxg1/6qqqGr9WLroGkMtdQ6Fg5WGo0dfaikNquNg6GxcNBm4JtOZkCC8LCwCC1BsdzyQhJFkkUm+DHN8UCpEeMvkRNCxr5hPgTpUTx/h9MfLDT2KeDctkzrHw0M/FjKVVSpBUsXaklKy9DKStGQ1FpBLemSAd+IuVFi/gNlEM+D2y2gfbUk6XWlqVcahlRRYfIGMiASEbUqnVjJzi8T+Xl+WE8l6J/pobGIsrE+VNiv1Adj1fH9vcV4troc3rmxa3S2ry9H95tKVZsKb4P4kroylNqZX82p4dzN7I1O60q8MF011PZOtnSwnd1o16Ibe5HpmdTO/vXCWvF6zOjsHawX5oeUsr6opg7W1pbq1fm53eGFVHVqWysOjo8OrRTHSiOjo4OjkUQsfmPj5sbMfKemDTaVK3Mr11Oz5VhnrLRxLZ5qrkRTq7Pjc/Ox2nhM3dsvljsba1ejK/OVRjbR1ldXhrPNupHZHt7X1bayYmiVzGwG1IXMzv7S6I3R8ekxbW82snCjM6QWtOVYe30snlkML3aSjUa8tGNc2ylcK0+N64uFxNX2QtxI1jZyqyPNsfGRlen5VmtjeWhqr7SUNuZn9sNaPV3IjScy0fbKTEtRs7vt8cJNZTQeHl9WyvODM1HtitEsDQ+OZKKd+uhBbCQ8Gp9JXVnKtTaGquVYtBAbr5c6pcjQUDtWDQ8Vro4NZsLtRGGvsBGObCtGamMoV84NRrKdayvDN4barcreeGlxbHVndqUeG5xSd8cHR+eGhxKJ+dH2uJ4b7xQizfbBXkdfNtbGw52hm5lKJdIuxOdnxneG0yvXOuVB3bg+auRmK4VYeVBrjLaHhlb2DlR1pDC40xlWY+uxwZmbyc5a9Fr9aqweTyxEjfHxSDoyWOrM1Bbr0xv6cme0Hl+cmb2pjtYH44n1ocrQWDs9PDo42DCG1rShuNrZW56v3AgPjpaHRmfCSnS0Mj7ezhktIxvLDY/NznaGh+YrK6OjnVHjoKgvliqLC8Pby+2hg4Mrtb3OeGclfLU4tt5o7V5PL3QODkaXBq/rByut+MjK4E4mOtgemh+PRQqjxlA5Nby+tBYv6kudzrX4IuCwFbtpAE43YjPp6Phga2OmFCtFs8rglZ1OLqJcHY2OL+9P5car4535lehe5ebwWGflmq4sR29eG88VCuMJbXxvO14cj44Zjan17HSicX0vNbs/X9xvTi8OZmcbc5mdTEpPpYcTsZ0dZXZxPTM3t6hOFeKL2bnBoanlpSklM5Vo1meXEzvp2UV1LTPVrt1cq6UWNtLztZlaYnZuNjGamR6sVG5OLd3Ut1PXbiRvLGqp4kYxpYxvryXC67OzQ0vboH+OKRur8VSyGs2GO4NXlhOxduPKzMaNRjgx1TnYK07tLuzdHB+ca5eMlcTCyGpyLZodXt82Whs3ro13xpZmZjYyaxH9SnksmVhrh3f2V6FQohVppueAPahaJpVaWM3OVhvR8YOGsR7eyM2OF1ujY6vFhcpI+Kq+fmNRHd3XWokr2yNDcWOucWVxvQO6bKmyO7yrH1RBed6pT20Upqe3S/NL48s3VyNLgwvzhSvT15bjub353PBCfWmktJNpXk8MjkQ2CsVSejdSnFudX5paaI/tThmVzsx0dfX6SD2SSe8YV67c1DeaxtXW9FQi1pzW966sV3aNq5FUJDe/puix2YXWNWWsftDOhVOZDDDLpZ3ZK9rS+MhOdaeq7WmV+Y3t66mFzGxufapYXE8aS8qsrtSu31hPVjciGwvrud3tqd1MM5tJLHaqc8bCxmo7vtGszu/uZmDxXZkuRBevj+wvNXKlqbRi5IaN0WxmLXVlfSEVnV9fWu8sjo9W9F0tnYlHllqgAs+v7TY7xmq7BX8NatcapfXd2uB8JxG9mQrXFq7HhlOFJS16Y227Wb46d/36jetrCSW8s7NTXtJ07drV9Hq2XTrQw9m9pUT16nYnevXa9dE1JTxtpHeztWR8fGZ3fyW9ND2zsbO/oqb2RmdHijuRqdH93aXsuNHerU0v7KzF1KnctLoau3JlpXR95KqxnriydnB1vLGsFowdpZLODq4v3Cyu7hrz1b0btdTiIpCfsnv9Sm5RndtZHWlcWd0b3x2KKjdWEivKlfjV0s2pzNz89RvaDa1SWEs1r8xerVyp5Srpmh6ebU6NjW0vKbW9WW11Ib00d721nlxfDR+ED8qFbGsq3qldGZnTdmbU+ZsHkYP6SnMqnN0du5Y0ZtLXtLW1TnVwda1SqobVQiS5nW3U1laNlJIrL9YK28XWtdyOYhwk9wazV6vJm7GFpVklNzM9NBPLGMVO80YxlSolp0qxrLFT2T5Y2a3NzWfmjWR0daeUWGtBK1f0teWl3EpibqdabO80MtHU9JyxUp9SUztjtavN/dzejpYu36guLerX9oe2l1aGF6bCU8VyezpZ3Z4aUqKJ0Y298fEbK8Wru810aiizPxJZVJvJ8H5xvrO+qO0uD65WtaUd2Lpm4+PFTmtmT42t7EdvdDqLs3ux2vbIfmrHGOskb15faq6v3lgZHa+nau1rnU7pyrWV/XBzIQPztLa/X1vai+9di82GKwsl40pbM5RYcmh6d2SmUsldm+9s7MX2snFj+ObuenLJqK3El9ZjN8r12YMRNa0qtVZ5JRfR90aUodZSu7h7vba6l00M3gxXp64N7Y7drO4tKHq0sARANxdujOyNXBu7qY2mjYS+Pn6wtj02vhJNp28eFFLzM2ud7GCmmFSWbi5Fy6MrS0O7RbW8vJ5dLtdX4sW00lpT1hMjzb1iZHShBkLz2sHKdml2RMssxAaTCWUsNzeyvTtWmI7PZ9MtLVXNjq/fmE0MZhI3CwV9R9nd3k7Ota9Uri6Vd/dm9q/PZXbHb26slK9E9iO55ZWWkZqLrEYb4fniSCy1u5IDZrfduhItJIrt8c7VxtTwyI2x6uze6urY9moiNwKDbEcWw3ptKtkxGnOzmWz2YGSqfnA1M3hjNTy4sR1ZK12f31s6GK21S5H2SOe6vpedb26kYhurzVZybqEIQzo4iDe3V6/UM+MbV9TFZCZjVKb2ZtILe7PRa1dmO9MVYMKl/enVqWZ94epurFLd29iYnilEFlbVSBI4mLp+tZ64Ot2KNirVhbJWHF6M7I6PJ9dXFvTkDb1Ybc0mogfzI4PLK4uFcCFdWUg206uNwtxidD59c6FVS6eB55WvZ2rKSLHVmhqbh30+fbXaHGmnY4Vtpd1YrCxeUWfiYf1G8+bV4b34uLYcLe9EdubqhY3YemlKU64ay0vXKvHR2o2r4bWNQtNoVxdXdtK5UrPZro82Gkud3Gx9bmcxvqFHG9HtpmI0N+KdxbmF2cXdWkHJdbZ39seXrs0pmeUbmbHI3PVGdbitx1I7SiTTmmqM7UWHhmCrSrU6DTU3fCW7E7u5s5uevzo7v1xfHx4pXZm6cd1QEteH9ELnWmJ/TVFKu/HaenF+6oYCAuhaI5tJ1kczRryVyx5M6xs3MzduboyVBiu7GztjQ9sH+tTNSmMhcl0rRJbndxeWdzMrI4YOvPHaqjayM3VtZ39vY22mtZtcTEzVsp2Da1dKgP/lJgy8GN0YXY9kdyvpg6nSenV0fXtwb32mvpqqhEuRm/PrqVl1VMmkjfGlmaViZyO8PByfiyrx5cbG2EoUFrea3J9aierAEgoHU6mrnSvGdWV+Z8kwtHQ0OmMsbbfS9VprproUu5nr5BoH+4W1sfnd8fbOzZ1ry9vz18JKOZXW6juLy6nqenN+dXbu+uiYstjOjtzYAaCmd0am4mlQWTci6SVVKybaU2upoVpnefnGTnx4DRA30pktZTKFnejURiwRXhy/mYoNA89eHBscu14zFveG9tI79dLuTDZXBHF8clIeGBgoqWUJtCPfZaW1rQekotJE/9zJWaWqq/CI586TuVYbfmv1ZtvIo7/tZLpRhxd4hNFo0yf/BNE1WyrUrgsenCFsm3zCP5u60fJBR37iPAI/0EMEO94KmGVIB6RH8xVxtQQtZlJuG+XgmCx8QbdKfVJugYaF2qL1hQ0kDwAC2JPsUfhORkb+tl6SIU5aAxWgYmNl/4qwdSYPL19u6CH4pYE+DArW4nQeVElUi6flI1rUz1CtGI2aVszvtTRD9aFjbkAqKYYSkGqguU2GG3F0ELsML9stNAPTeWDIxeLolopu1LWdktby0QedTZC6r+lGvkHny0+q7GlGxfSRDVGfVxXdRJXWwSy88kErk0K70DEoggbvF32lYcpgW5gQ5qfW5Ooq/RZCfx+/VaB1YJXGP6wUHTOONkR9Z31sOv3oMwQiCyrl9SItEsBafkkFKAiC/F4tlqttveKzf4KJKFYAmT6Ek6LVXgD6Ysi1Q8kql/WDepEPDLFWb/j8nr0Xqw1ddffOSJH1j7jt1T9xt4caxF1qEnTlZgMNA26w6NzkyyXAO5RHN2CfbdLg5XI+M4P+YdJP6dNMKpOczi1nNvyu5lwT5Bq+2aG7Muj/SrXauwGKFY8GPCsikkLtehW4nq+m6WiqsAiYrhi0WpDF6Oso1baD0eDHUKlda+r0K3KpEvQ8GYXlUNeRAZAwBE7Pg5L8bJ2zPejbOMizA0ufveFDud2sNpQSLOIw2g8be3Xh0WgYSpX91uodfiQECx7tK1UFlmG7yb6TJ6yPz0esa2zL7JnQCO3dNjXsO0w6GSbW0em8o487xYmTNTJSVfeLatOQcImnG8YsHkERD3SrcTZOBw7IZ+TNO+oB8gLiGYNM2lEuBEu5pnOc4R+CfnQQZCfF26rhg0aca5t9hra1osHWN+4fA8LyMA6aKptsqEocCckrBo5fAvh8QpvmzMMnXFIUlH+Twn47sYFWCr2t4VeCDF9ZPv7782cv3j394sPj+592P3vj+MHfj+/fPn348B/fvnUI0B/JfpEoGPCclTebVRMledAE0TPSHJ9FFgGpDYwAKYDBA0XVPLoeWejaFMloC5mB9UzqMJoSa3Ay20KcWW0iBqDgTzxLEnyHrRYRKlebhFg9WiWFf9KjtNAyX0KXL5vYsFaTWZm92YI1CeAG+QgDtikTF55Z03yHdQlQQWs0jvq21SnOibBKcXpsyxT/4SsVAz6UPDnhtzEgdHNtYMBMqNyuVmuKUaz4WvJmODi+dRgJjB/5npl4NsQf40f+Z4AziPU9CZLR45NHL5+9ee/04Ven3/+6e+uDs7d/f/rFO8evff6Pb1/t3nntyXd3pDlt6h/fvhSWnjz65smjO1D47A9v/+Pb2//93M/sFAtrwseCmfiKuixFwtHhy5djnMFyCm501FaeDJdTsZ0lhmFJmXNAOeCW9G+TnjPqMVeO3irAwtSWd0/lS7SpyUNX20f/V+JNCl+tXuA7AU34yECFL+p+UwPZNnyJwaKrhrl+G9SDzFrApFoAQIJSJng6skOLyRUbzQPGNJFvYQ3OsZCpidwWa1pom6SFeU3SibN0iPpi+hguwgFr5GHbJNPiMKZ/t8fI2fCNRx2cX7NAoXKxblQHLDlRdACiQoasyAGX9E2kQmzOApi0BOIY9oF/BdgbbCmfvGYJAQeaWi0BpMUqRtRNA2eZbtTrahFx7xNi4kLorGJ9YnDjeIr0pU9Xq2VhKaHjC2CVxqKF6D8+9pSYza+mU9cC/Cu6xuSzuUwysdRPam0QF12DSfykwxB78LtLcriIDIWbtM/uBiTIkGxzXs46tmSrLQ/JkvAKa7gIjDBmRtDIqvMWl/M56RaVMZl6JxYNcnqkVxp78K/oqAhvgyT6JmU2lJrB52CQsBA54Jb9uNpIFRGqWzEVkmtOUToeLicwGteNEnyEf1pa01pJ7COlb1QVcEcMk03Ig+EqwfLWYSx6ZHJYUhBZH5MMInG/S/Ahn8RVRKQQAY1sQ7eze/uchojGZRODxMYIYkwaRj8wO73L5GCt0tDxmM6BJhs5WjMKjbjmWBSdaNAF/+YQfxyg2cHj8Yg+eS5JvFGGrG+67Bd5UxPeqAQSszJIe/yDHSD+NkR9/6UfTUrRcPhcuWyJnHFKIJUd3//m+BcfdO/+8fSH33R/93sSJykdOpo9sjY+Oqo2+j/qdsnZrIPSs6jTcfGMDInWJOIr23RyhGf7A46PnBmzz+KglfqBz0OIBYpE0dUUT4mgTZ9AwvaZUuJ5YquFnU8oUkBmPX7tpZO3fn7yxcPTB+9RIcKOEpTCBSqa7MUqHMTiJcWKCobPpWEEJIvCM2q5rav0vdA+PXGmzFiqKQegC+ggTKtKSyqoxp6q0nhzrQiFjEZTJ8sZJrpl6KGeC82lXgrUKfJT92qn26yp21zGHQ9mpqgyGYBZu8gebbPHUOOKx/6KfwpqmUr4NlWPbbHWvFAuw5c15znWIGjUPHz31DZoJwHpMn32M5kdWyTyOP1utran6PkCAqqWLCFGlPtYd179e8lK7KtDVhJpjteHZc8QgkFjsBYYIjw4KP6xWclY0YBgCeBwWnYyy+TFemZzSGinz0jJdx/DGcDmkuGc68K1gwaD9UaQYJXsp0Cwjv1U2PirDsDECcFnour2BvZpQYEV0xMWtg5Y0w7hnDinw98WSV+AnOuNPaQqqBqqNWAkjbppUWA7E23EkoJxyKIveUjT82hyE8nBJZehY7mdsduaONc0InJEaGpT5myd6t2bHEiucQRMsC0tg4IeRu0HRx1kLSkGakRSLOy2jjF0OxYk56JMFAwIXD4gLagH7FcO9hInE6V2QV0nL5QyDACQ4mBljNSExcEmgpS3zwOf4En60erIay0SVIsL8hDHPoHIQK86jtAJaZP1ZCGTvRBwecRtVsCxrG5tk9rLQihglrTrIOOSaihaVXcombglSRdXWwkREq4w6VJ/e1gMXU0HzjNkOKwWCCIaJuAfwdrIuKzcUtH1UCNeezVl3xdmDBjoEGv4LV3UNK852qeKMDNQUguHul9R2sBLBAC9LALcLIJ6g0lndvwyrAs7jHMeSLFtrQBFmC2Cnm+0UGYvX+p+9deT33wsHbJqmxQdW9IQ1pkIxcpHzP7x5NHLT759VyzIp9JZ9NVLAgLKl548euX0u++EioJJyVn19iVz6ZjF2fRb1MpBp5YboWG+xFwAdW//6cl3bwolrVl1lr7ktT5ojzLr0DQCyW5gnfPrAptZnaA2OmQT5HcfvAowPnn8x5N7Lxy/9bPu8/epOGlfXzzKCHRjkLZKungSiJIIfettEUHaammo2Uk+O3Fu5nD32Xq2vlyfajSMrFqcxN+rdc1I1ZUiBnzRd7KtXlm2yh+yro90r5riV6sN/zkcT4zBCpjgB6RwIz48LOyrrl25pKiwHwZbKiGwfiVBfmJ7ti2oy7VpM/g5nj1B9JCs8BwN0O1dvM++aTZAlG6iu4d0kNaJAv4fbvz6iNlz0K//H5mfbkKNJZt4RprqoXIYPvJ1M7Jl4/C9QuUYUQIdamT3KzVwIdmMtfQVQE5ecmsDiA97agv+haUH86m3gaj3fXLIWkNVte6jdf3ST6ToSAxFRCjAkxuwdplMC/qHT5gqu51CCd5ErPiemWA/g1uH4UA8csS/EAtxVSmoVeHMDFomr6zOQnqzqhkWlH7eu+vzZjCytRneAqFKqTYriq+v4dk0NsPKP37tCymRnU6lpO4773Tv3UFO8P0r3Q9/BvyisX8AlEXEZQzzxk+P7nQffXjy54ego//3c89379w9ffDg+KXXT7962P3+5y6LNAWTG1rQUJRHYyQ31ZAN7CIW9pGjCxnUKVzdH26dvff4yaNvpMh/PfdrzJYyIoG6fPza593P3rBAJFbRSctyZJOZIijtkRLwL20CME+zcNWpUMGfQYgaC58P1dnbvz/+22uAs7MX73TfRzQD2o5/+xDgPH34/JOvPzz75FX88cPbJ6+9CeBiChRo2IVS7JMhlASbEYTqPp7jzXGwSU2/DNSAlEfoq8Aq1Hq+1dgTqplnlV4faZvlqrKNTt7B6rxRb8qIKjOzHB5oY1odKoRgkTYUMQ8YoTnsmTJBjF3EtgI2Q6LftA4iTZO4UJGIBW7EieM/ntUvwwqD/6Dnn7ZLTf+z+qD/mWezg/DvsyXh7+zghA9+wnfoGmA5jzkRw7WdN5F6JiE3GrrKEM/UY+LHUdZaupFHQZ3bQymfnLQypnANq60foH8/R+CE92RKP5VYqHEe1e1WR+VFqFONiX80KdnyKB2ZNI6y2eGRORXofxAwK+pY054Zyn3aC0iyRkZVV5YJhud7oRl0nLmWACf2LDNHdjTjAYZWb1saEhPWLard0eogE/NlR0bDwXMpXUQGMUzc6f4QkVh0Zn+1D3ITW96i7JQ7ZNhgP7IBxU9nrOUkIN7CZVngETjDm/zTlgUuGcQmdooHQwIpWZREp4jqA7ttTTUmCYw/csJoTQXboSi1udiF7qZb784u8/5sjkjmGpfkITl0o6G5kElGQ7sVJL1tkEkNo2XvCp0yCASMq3Gvg0nJlouLWF0tTyO6LU4KmYfMAgEa65yVTh/84ey3t1izRVw1OGU6ryUmwhIqe6XwYgiEJhq1fEUjFrGyfPbW3eP730iHVtMhIsAdwSZjf9nAE+7IEWV/rD76wpkuDURgp+Mm/FLoim9CZB6ozxDHKEjWznNGuslyxw2rVXKAz34z2iBrS+yNkAGddz7FAQFvzKWsolVVCfmz2/nDAqxsA5KL/2wvIBsFo4HQAUwIeU3c7nwOmf6QzPORxRZh3TVRaDuS6CYqbR4iko62JNlvO0byNh6VKaw9DTRUIsEwKooNShKicOJy5qJInfDiPoIDDdb1dpryOP44e/zb0wfvo3JI6h8NmcM/kkBB6955F3Q0kBdAajt+9cXug7e6t7588vh1LoSJhn9vyvASvJ+GCATjlQU4ngvDSxfGPSkBigsU4DEfbqz0pgV014Gej2TYAzHFJvy2G8qIngtvcUOuqpOgdaFsAWD1ms7eU2axJ9tJGv/DFre4fkVZtx9lTYhCaA/R2JRI+RZFs+TRzL1Yk61tdza/fvKomWFPOvndL7v3PnVJzeHoCBec+4mfFyOhSU8OyyTKlqqSM+2WoZZ8uHsLpMcNXKJYjhX6DK0sH//1veP7t0/+9M3ZG39FIdqDk1A+7lw9lrKNiXBDsFVqRdWH/XE7CEkRm680mkwCYxNFsscEyHZvqTJU82QaJ5m5OpCP3PvkWBBvRf0HpFai/fiD5i9TERLx4pBh+2h80urMinT61d9Ov/pPioLTV/+z+7svLK1PSPhIdZQn3/2ABjocgNS99bezNz6zsEY2QDxCQ7GtpjR9Gh4QEWhC261Gu6nzo1dRryK18AfW4/pVX+hd8FJq7d7/WNDxui/cQi7596+6H70Ceurpf2KKhCff/OLk8a+P337HAhoFRQoBMUj26/jszZ93X37X1v3Dr86eu338yp9IXd430Ywf0xJPvn3r9MVPui9/3H31VvfenwFGWr/70hun731sgYHEnQdZHQXey0g+IH/1EvbhkyV7MgmeyZmE/jZlUlDe6ikdn/8H0EJUB7dGwOS7IwF7hkrPxc2I6XwBmP62KgtqAx9gSCnB4qZguspvUdDlLTtSQpieTWmZ9djwhAZ4Dcx5VNWKhsVHbDovZ+0E09bMW8o90KBJFrytviyGziYjQzrFfJNGjoPr65A3tBneOvIgvElK+pOTUp/hnb8gbEuBQGIR4devdN9/ncPTg9ltWsuXO+zx/oECaXZqnc4AV1tRSdWlSW8SMHmjbD8IJJVcvG9zy81CaFF+PlBTWgdSXxyJo/Ft+lhbNdBQVKI4sjZAGvf7t8SFz78QWXRzC33FhcAVHx60sMZ4yUFog4BJG0J4f+JqxolF6t+WJ9l77ZhkG/8Fx7bpo/Yb/BuZQc9p4vOIBWm3PgvBJN5DqwGLaE3KQdkRxQMKCinqd9EpGR1IZFTdOTQbOTqEr0eyc9BIBsSVrr4tmEfEwZsaBJMJPUhowOGQcEF68zEPG6oqmcfsovqB7xx6NBOj7JNh91HAStbkECd5mrqJCHkc/aL93ZQc5Y2huiz6R1C96GAobZ1HeOlZtF99jxz2Un2pLHfvPcTd2EynLKxvyhT+8e07oCVxXUJUlLg84hSCWR/EnIM2nAPyl0oMO3WaZ0I+covGbPzorSI0YFY+Io77xFJOPyMKXS4npgNNS1V2PKR4QXA5kEAYkerIxfoI9oznMODsUHOyo8KY4KihO7Bu6vyHDGDk40HzIbJ15J5PV/ZsW4vM3ica+aidzlaqFxWIwHNCsCjALR15qck4HaaB4UIBQtbqu4Do69kCh9lTd/Ke9ovrmhdV97g47n0yeeFBumbOkhpYEx6MxcVUxFUARMWkYdsWYGuBlLDo7sIyAZEGTn7xOShDkmgeo1RCjQkn3/6p+/ldWkEQUtgxb0/2bBaAeenJlnkhOSB5JY23+LWIvH+WU1+UO7s4+jkDFHeRPlsVLycw/14L2XOtqdgfYaR8bdOpPHvji7O3fvOPb186+ehX6EMAylksTJhgZCQ4DDrH7c1DDqu3RcxyKTbnlFoaxGH6eP9kPls+/t5/ES7Nliq/HiiUaG23a9Cg6cTUc+leYNniZIv0cf50ecRieKnC3VsvufZR+x76aveFO9TYJs6FTfG1qzOWLELM+szRrmdRc31s0SNI8mCzHdmmSDz67GUq4Gelw0d+3zMTQfFZiEca8D71sknhjoMv6zG6hURiP69n7Y14KfaxuMv7mwubWLC/nBlk0qU1i72pzGdbMmf3n0PLABqxEAIJ1g+1DVATR/d338C8srXErPpkRYleL2wSuExbAPrb00pGxRkW1uPAOjLsdWJdKzR195EznxH8CEjzRS9fjseIziINDUmRfDgcxv97IhIrXRBDFql3H33YffCdKVmZDuU89OyL49c+l5agZUBZWDp97+OT97+hJg0bhsi1Whh064ElT7Hf/NxLoDcLAO4Oj/xixBXq81TVQZd2ctzZJieOJIrPIzTVdfpUFjo6NJs6yiMKoSHCwQecRwfuQxfPg0vvkwZzOJtmd1vcLaWP9GlWCzUbTZ9ZVQTRbU0xMYc9mE+uqcI88sCaSo5DQCbkUMuS9ykgO0n20JG4gZqf0Do1fdEPk5zQkmNcggU0D/Y54/4nDE5Pa2xynewKnBAG1FPRthmYnIo2MRZYdCseFntZ1iY8z5o9HQIs15WnPkMmf/PFi+Y14vBJ0gPmzXzCNhsF2X7KSlF1xtagG4dGVl/wBsl4SasLIWZscUInTZIBcrvaKBBp0Mvlgw7KhAENosMT0uZWQIrjP9TuWFH0PN7QAF8JXZrYNaFE9FogT9j8qtAsavtOqQn7zLMEk5tbftdhFhE3oSotTSK4ZKJJYdCP+QGdWShBEBcZ6ovBE28QHqU2gXYU9MdED1/gyySTPfUXLOF9EPDFGQnkyWgEROFGwi8EDGlNPocErE0G65ZdhjNx+NNJ3koIiEBnUULDphRuNqvn0Rc7T1pz2Q2sQnR6vaqTGyiLiu5xZGpO+KYDlq0QBgjVSz723u7NbtYapoK/OSjeu8AtROUBC8VlW2RSgtyIWVBBL8arMBsdDeRPKZ3I4fkVcK+iCrMkpVagcaPSarS3K0ANutRsF6paUZpJZ6EFKNVolUK9T6HRlcoKVsVtCUaANMfZFHWSQ79xGntkBbKm0slc/0BWJn/zxhVNdUeZMgA2t2wrgrtkwceJc8kLUZBg9AU1APWgvPr//yOIYW8SMENbSWohNPOS4w6/31zjxJ/JbMfcZEj8B37esjsb6razfI8I/fufdO/+EvRoiV711b37kJr5u7c+Pfnul5Q0UCODH3Gpe//z7tvPuczsZsR2j60YVVTPrZjR6tPs3u4jY3YVF9WR6QPx49oDqrXr0zZtAAnTWXqLbOD0gNRo7Kj1fLtV1ZWy6otF3R2zW9KcjTo2HNLoObuRKGax+k19pxfwrr6w7NOBTq5YoxjDn3m8fLMvrviebZaeRALFHyH8axjEnIBEPsL+2DLyWMAGTUXd9435A97HdrQiDZKclOfaMJuDkld9t2ju8FEUd3fqLCZN9jaVsGViF/lcEypovZ5+kYJTJA0YZz6RorMaaY5cEJTvcTDCbgHcEmlBrMEmx+PWQ2/KoFWLbd1gLgyURKwWB9gWgZGYEguXBhEW1HIYJznP4VFUZNh42awiYVJyehsvcCGpqm4rxQN+4zLdIi50SuJY9ufrVzbvTvftfjZXTl6E4t+l2FycO7k69fX1BvXbonWfQh/5p10gCbvQL8rtxJIXYhd0nOczh02x4BbzBbTxBkeLmFDiQi2SglvUMdOTJUSinCUAZeZJXRbiQM8SAdUYiFQNSHtqodVogPpSVIE/CbsPZYrWaxIUIWRXx47Z1dchvaJER+KsB573ze8PASglDa9U8/k3JyJxeyTdgJD+h2XZ5yCy5T/BYZUJsPDMgJYZ1PCGw2+1ZkKMoYrUUZREyaCiid9k9LluVH3WgIXKBIVQoicRYEL6A4tgJjyQHx22tdjW2EYyIXlsDvT7U7RHXMHyoOC12BjltjcNjJh39z5N8/SG1fNrsHtXe4/MarKlKlXNODC3QM82x+i9wL07FufAaltYYd7oFRbMRL/lQts0Ax/pfmDyacxxNtGDenfIhQkklZqsqEopWFONSgPhkT3uOsKbI0po9AjWCMlHxTfKPrwZFYkHd+ggZpkgE92kee5IBqu8ildLNQ/4FQk1RcebMg5lzLNQIFdq4LZ7JLRGN/xgExhwkMRCgooHxWjIgn381oVTFhJEIcIMhy1qzYqKN1K4LnwlA7Mm04PZspgFBqhH1yQeGFOnBFgcC69rk5OVNrEssvsQGJ3kC/FhxojK8qELuKOJQ97WkSxwrJJKf4Va9ExFnpRtVgpyOrx5iDAdbZHDYHmCnDvhG2rIxl+2PFcw6ImhoUME8+jfD1lDCAAM6ejHh+SyeeYoipBPXrrkN50rvGQ0OmrrGF7Qe23FgTLEy4LtSe4ufMOvdabGt5R+piPLzm+q4g65nxhcLIm+56Ed962xdcp0/rhXn2iaYZPBJ4vkn2W/cUv1BJwPi3IKo6XUdSKUeJI7YyQeuzG5aEU3rI+Wei9jflJcwHj5qswJnd5qaAp5Xv2RfcrTCEory/4LO6jw+ElyK3YeIfXqUOyMFTWUFjxS6xfa5ikgNJ2ReDW92weKCHs+JtLhplLSeG4Dape1xH23xfafOjgQ5Gfz1iJ6zQ+JboMpKMvsJrCJQ9r1JSJiXNravGS2emnrSBZ5MLlw/FBmsgNuMmwweHUMHgIBjwexp4mXgQb4fuAo1mxpHfhAC4k8GbkCaZ4zeZM9evJPUfbYEtvRtuuYd4r4nU2ZWJmgjnj8WZSSzLtubb3jZbcB8s9Kq4Hns/gSM3CWFOjRBnixSmoSiRCTQBzK/B48rMMkRXYh65ENVl6OVeNyjL0KikYMKHbfYaCXc6t1IeIhseySeea300UmDilN0akmk0tyL3D5yeui0sAF/GjF2WE9yMLcHG3xLZUJ+eYsOPWhTdl+inNIDkNaOIhD6yiJuhRuHZGjP/k8+MiJBmkGJHtSkyhq9sOzgEQTXDG7vZ+wZau02feRyCIozGZ2v2U2l1P06kMfzT6Nu4sVRrZ/MEEywbKcUvQuR+DjE9Iy0eaUKtr1tkSHIX4BY48iPLMjDtCb0QQkfhmjmK8A1zC5Xgl/aGUNbfMXWdO4fPGG7gusberoSHkn8F/s7qJclRyt2HkqTQNIBTA7S7N4/gQmYcUBMbqm7KrCF6Y354AFXG3i2ocvMWdqEsnBVoKUKIIFgbE4hUvUY7xB4VZFUxHaMoGyKz8ik7BAsMMpci5+vWqVCKD0om6npkS5G9/UsVhuekX2AM+hV1kwOlQoWNlCH8w8NeHSGGyHEdS4RE4PsGvZ79a4LjiLTvXMDg1RyUg93sLmocjqeHPYBVeZSLOCLocoLlcbe/BxLUXu9fYkDq7VBenqo5qHSuQfkfgHQT4eHo7RS+1wtQYRFAKZWxTZClwsfMG1HMkYuJrJPsoXbo3opUGCjk1HW6bKuuWYdjIlvZUkkfVbgno/gyszngnym2D7YY0zgZNuEiax8F2STj5Xea158ZZrz0HO0xKQaOk62jL3PPMUov+wWCn7uM6FwC0duQ4uRFBc6oYXJLQQAcQSGuWJCaLqeeogzKubiZXyeXhlR53Q6jAOgejs7lMLh2bMh0DPJ/qPgJShA3BRBn4LsgOFIEMo61w8azhv6TwtcVhnKVtH5zXtZiuXL1uDoyPZ2nQWu+haF3OOU2Ylbrf9uJVY7p/ozYPH2I6FCIOhgfSYdElTqqZiCFPprSpysnDVEPJTXkzPslOQEItiIyPz/nFrYZhCtsyMtqIsTA5XbJR8Abz1oC1PIf08EZwtfi+FkGvkSLFkSI3tYFXtqOTW1T2lRVJ0iaazfQNhqQoiR7Bdx3s8nNmCiSHHqXmyIdmGbyo+IObjr6OgVrdpPcKl7/YDVp2lW7F35dB0TabV1yuiP/fiU+o4lCMOSAHp8uUy5kvRjwacmgc1ZtGvxPDCaItHKXoYl8w2tkTLMdctL3vcdo73Oidy0/MBegmK7NS3vLm13Xm9r58I187Ie1wKSMIX2U5YRc9L3ck5UO/TbpaOilvc8OALn115ZIRuPK6ax06QEMx2LsAqWGvpRC61lsyb681sz3wD84BioanWMjXLdtbIX4ZAQsP5DhIHQA7NeZmPuy9+g6GMJC9d9+4np//53cnjX2L+g5c+x5DLe9wXgyShsidC+LG02qQ397Bbo4hHj1YvVtslldw6BZJ6swnqTEkqHEjwrQ3rmaTMY3mvXNNvsQZy4kaatfRv4tZCk/viRPGBYyaxiJCBr7GvqXpAqqEXEM2VRu7ZnSTeboegjpHp8qBye5ow0aPQM9RJzM3EDhLdE9TXy4xgISCq6QFTG0crO2vNSnHjrk3FONYQ53Lc6AOq77aQ6AgdoDkKCS9aXs1RQz2S+5GrcUAjdxEiHdidkTh+LejIDsYHE9RwJ7INTa5aN4fwn0eODLwwUyHcAKBPcxTkrY+NETi4mboDubjf76IiBjuhIfbbVYayOyyxeZn8drE4m984Q5vXSf6micWpVHomlZ4TGAPHUR9PZJq7u9lSO1qjrbOEsy0Jsweyy6LRg4Ttq8o2ZsejyWmZywM6RbSFNN5iOiHTMINyDWYixIhSc93wHcIRhOI1KmtEvGnnSmCNhkSTk9cisDWdWrEa9migVx9Vz2z8Xh0sLk8Dj11Ou7upincBOc1taPDyXkP2W1XkQ/sKClqkKTubsRExl1Qc4SZlOZUOYkuBQ16CB2eYLIyxHeCeNKM+hsmx85uynEjPBHy+Q9LekT/gSydz68uZhcDqzIrfH6C8zhH1zKkfBkOrBQ5J85uXkJlQE671zWyChUATOwtMlS1k4xznWSEso4bspSREErAyeAtYszOcp99tkQNW46yyde7k4cIq+Ela5Wwukvje3TtxqkZdIeAMO/NIYHH/udMPnze9FXu5KOpWB34zUT7dP6lhRkQhj7Cwpde0Zz6h+fsxZb5P3pSFi7pCwDzZ+y2vqA3y72ZkIhjZct+McfG5c0WQCnHZQnZQjxSiImdlfiwtM8tmQIqQRJs01Fm80IP5W5Mb4qiGQO+Gq9M4aNMjhg8+VGnU1JDSairyuWLQk0cvHz96BDNJM7HQyaTJOqnrqV30safeFFP3mAtCnG6/kxmQFeajmffEM/fLJJyAKGKTGCfOFSzyQI//yU+jamY/1OsaeQWMwBZMArjF9rlkYjKq3MZKMntO7B7LvpK1tKL/fu551LmyI8QTl1wZArpYGniBLfXGeelFSW4Fnl+V5KnBOC369iJJaug0sWSfjvyjFiDEP2DSsbrwL5boDjMrwPfoyIiJJaLr0ZMtykwx88yAcPsICpx8ddmu2kTpk7bIQhZgunzFitLyY+L6KEnLZb6BbkCNJ+IlvsCJcSwJJnwKl5gwerCIwd+XG3Vf/Oz4zoPu+5+cvfYDzFX33p+Pf/FR96Uvu5+9cfLph0JqVi49cqHRtpVZujElUmajgWdKrlxbNafvyEZ0THWecKYM4ENArFByNp1Ks8xbJHveUhWoUmKs99Wvz27dOb5/p/vye93XXkB15eV3uw9fOH796+63d7u/ehV+n7z7PGLj4Qtnv/rAdZELBcXGUaPhaDTo5BugYeV17SYy0UhcqGjxnEh0LLhdrPEtORY9PzQZ1Tbc2ZlPTSE+zBxjiJsT56A0mIffJEniwBgueYLiCdm/NdA3xL9331teQTnkIyNqJH9y+SQoySYWBGCwrP9COeeOP3sfJhvRK4mzRGdSmiJIkE6+fR0mjCQX470dSUDBpy//zGsKqTzE/MMZm6T/CCzU8mdCVompbD2SwKOUiY4gfNWRAZM35uojOTdMKqcnCcQzhPrDmDXPo+PTLz7s3v3KpE4MqL336vEbX3bf+3P3hTfJ0sVHzFT8p29gvITpwt50/NJXsCux5Fv3oOyvoBkXSXsACEM+DyaRsUvdu58c/+bh8avPYx47Vwew79CrXkhPPzJ7YswddqjzN93Ht1jiBG5/ePjk8Qd0/DRfM92BvfqecKvCaNXX5C0PsQPe2+rzOfJoxLwjkG/Dbv5rUlIPAsTNGf6PRrtDWd/RmkE8ZQkC+9TKB9wH8Mh7trh3hdfoUNTH0cG/NpEDv3J5HH/TcDLgSc2GcGUby1ZDnMDFY3pezisx3ia7DC4RnJ0IbQ0+u/XTzUTwOk2vHgpuDWIQ/ITP2uG9guBpphjaR18p+tff47VkRHY+fvdbZAm/eZNcHEuScv7xueN3PuDk8DxK2b961Uy5JUQGUT4CPOX4lU9t68ISs8jpIAXITKDHoaXRpkJOChFtHtlh++9OZEh8jyLZQryThAmwoSArdMlDScmOkBemlxh8L3B/KqbHt+Ys///86P/86yWf//Jg4P9OTgS3fvov1gxvHUaP/JcvlAOezRWRNNxz1X34NeVtdMMF3vbk0Wd4l9rtr48fvEzlECpmn7z5ffclWPZfUX5v4cW2UTIktevUe5PRM7+oHnWjIs90zLa81bqG+HJe0Nx3HBSE4zfePf7ba6cPH3fvvk7AoelPBUcYNhU6i9qku/ZFLrI1Z2FwKA9rZ/IwHIheLOW+m6ZwZ2RbZfeFW90HX4uz0B+NLjGDipqDkjwpS5clX9CUdP3Sv0jofa5UDRRW9cmCHMzLTpGEu/Ha7rboI3r8c8M7d1poZiFrgVxcmxbG+xNpLDIe/R8J8udoVid//e3pF188efTc8dvv0YshYKx096NDF9KfFCsqbjv5ADEe0wRKdAQwWEOjN15ODA3ZyuORB/lhy0SGeyb77JTMrbbZL7H1H8v+zbDNEio/Q6QcVvbc04Xvft29faf74jcnf36ze++X3YffUokC5/Pur548/hJn2j3/lI9QHmGK9cd37z35/nd4yQSvDEL/yXeOQwncrjHwFxRjFQaC8eABcY/jg2wJo/x3h3TBK9pHx1vGWMoe7JgXcUXtomxo5QgnZdzCsrsDB5Pxbl4YnLmt2e9fGZL9fQzQ52HMGxaGR39PRIrBjd4IvTA3+Pab7ue/pKo/o4Y3P3Ya2QgpM5E/b8lqKC6x8dlWjduW47DN0DC7y14CFf/hN00yPXUN/4Bj+TEiODT9bLnIV+GxJfxfXcwH2I+XPP5Aok0AKwDRiDVHH7Ah6xeGRhD7DQmSkLrfPtd9vzf/cS12EpX2Y+/l7zGP1FwEYho1F4mdMOWFiEQg1p0+/EP37s+OX/scYDu5/eLxg79bUFDJ2DLOWKjsgcYjdsxOcEl3QXJ1msD/KHrFqxF4RKwcCY+F5d5WIRk9VshtcFWWY1+G8gNPxXicS9NzBbm1DoSOODQO9GZTWCtAkjVYyi6NwLrAOmCLVazNlTmsyn/T9s5X7XC2Tx+8D3qcTQymKi6ZeYcC7ObjLgT047t4dWmPzxRkm8TtaYntu9rtGpRfMNT20RCppRZ1YVvKK9Myyc3q7FhIjBKx6Stcv6VGuK0Af0H9fjhFULvnpDMo5nyDKtO6Xn0R92i6Zd/CG6IxdQeT6YlS3r37IYgu3bufk5wemLec6u3C5uzky16HCzT9jGUqt7JdiFkzPJJ5iKZyNE9OeqTtOLLdpixe/+lI4OE/Hy9PHj0+vv8NngFQ+fOjPx7//h56RrhSVNA07sQccwtPDiwsCJKq++b4/gl+7HfA8/vM2dV49HrtQ8QdT0TjTtVjv6zbuh7ehuj++XqO3NMIXXNbhzl158xcjzQsvSbRpkX0TLxi3tZq5UUB0vpXhO/8uf1fp3Z2txfe5msPluDBGQqJrcJLg/MziVwCwxloidCBUqvKAzY7uVHxuruXx8bZokSESSb1+l7Yy66VwCImD+QOAT4KjhBMorGlSrkNd9anRwfMR2b/gAkEOBBCQNz9QiCfmlJXtum9U4ayTaoaNIsT7wX3VGVbNMG7T9dl65Shh88Fl68oOBP2K8gICE/jD0UFT+oPdfrg8+53r7kskTYIee9sTJ7JBA+PBpxeGlQ44Ojz8Luw9eh0ObLc1c4b2vEbH53cfokOkKpOdIDWZffU88vD1cu86s68Ss0Zi8TGvGlDyFbAc2Tc7cP/NL69Xg3Z3Tv8nNiY042J154eOuKS03TiUFMvqj7Lcwwjqfw0Hycl4B8BBffwrnL6jPFWjvqf1uFsUMTTOcGt5rWXLPTzxWm/Yc7y8GH5PMQe3bfL8cM+7tWFWPQexgVpTbIWv25eP+RAo5lphGDxYgtPxISDOs17MCn/thOo21UORuukUbejnJ3BmMhkAd6CJ5v/ad3QbS2Zfm9+mxDKgRa3DjdTZpj7sZTlsWlol25BQWCbekVpqcRNjN6xq1RJJp1mFbZzLNQwgo06vGL+Y7ifhOx5szz79NrF7CJssdFS+Sf6T4DlDm20rPwNgqyD+x7KOsSTI4iONWZxfFGWOa9wyj2kP+7twIWgaNhvZYclgg0dECoA/e9lwoBXiS21d987++TV7vt/Of0C9V7zmIEJxYwPPu84TKYmCOCkx/c/5Tv/vxPtbt+gbKLlcvYoqHnu0MVcKSmQuNFJmMaQTEyO5zOc4ZjBzKSTpsSAYr8KauOkGdUbJG0H0ftHJ+0IPji8DcD/CogFPvxsLRjSM5Os6D8+0ghND+rhXid8CCGd+Hy2iISww4uQKS5iLVgK2BMuPZ9/M7LlUFtFRZeFJ5PRyQGvLCJxp9snSXHGh+wlWtFFRAngki4R+wS52YHPjKQUUd7UycumgjjRCZ4A2+QqL4wfBxVeo4s5JLS6SBxAcBmaOSlh6FXlQDIa5DXmrqqqPKshYKVRhbUlFVR0ziTDFNIbtkvNvOXw52DINsc/hyWP1+Neu9whUHQDDPhSK8Hp1EwmEAmR/w3FooF6I8hggu8z2VwQs3oFRmJ+f8AhhMk9bvXmaxeFUSp8HtovIe8bBaID+dcJZ+DC44S0SQbriP+xx3hY8ex0HdCgjv4hM1R7NCM/ato+OhgO9A2TIUE11AvAMQH+nsFzlKjFqBkzCYorMksIvjDnEOoK08YdLwOCjygfs2uKTFdm7q1p9XYkuktfgJE7+EW7AJ0W0SdwpQEU5iM5IpE/+TlTJ3dwmtU5Z8e3TLk4N6ALNFStPil0NZNcS68uLmIrqLt6fTq/SVAdPSoSlsfeXeAWgRLslnhrMqxL3IhCtQaIPI26VvTh5UYjrvL0igLeZ7NRrWI8jnC67Grl38w+vC/i6HmRiJOnA8NEBwhAep1dzmvn18yIxffTcCg64p/oi0bve0QEPX0528PLyAQeR6tXVbXpAyDcVx+4zyb6KfFfHL/xJWzBx/e/wV37769QJR6zid572H2ZXeZ59uKd04eveV/gSW+gpvzAvgXZg6y0OkpVnteRek9trztUaFlDbdWgSeCZ/qefYt7InqIZPj55MX+/aRGoPkcrJPebsEJL5/eyo+GwLgaM/QpHdV8z8jq51Z6lWyo0SsLljWaA3XS10S6VqyDFCmeSLJptkmgOPlwN3MltkvgHExWILESMuYGGbReak5OLSZlewy4mnDczC5HQFMv+SLvD4DMZ72IA0QEDldBVh34xhXhugDDhE0wvZHx2sRd912xtEA86wWvOJxc1g2QVa6nb9DZvs3P42WhtCyYPE2WplfVKQ3N4V4qQ6u0izovs59d1uC9JcS8o1qoEC+j0h990f/f7J9+5T1eZrM097Siok2Lf7F0eBXFM58GfiaXco6BDJQIVjfZBIgB6z9KR5fAEsjU50PF5rWS0+rZbRTHRIhRpVUmyaPzg5SeB2UiZgbYIZYnCskv+DlqCSjCIOcXpr3qDyAXkeIa8IFoo/pykZ03eGxQUZPw5yJYyVhmjTdSUffIWnyIj1jvUFNAfEt/EoqPxsd6Nc6DKMjsHFPL0kIRotFUW142/6Qsi0QUJON5NP1v/l0OShICBfySZzyUVHxDwPLHlkVwIZYxj6QkmRTH8fSHNLzLq3RC514dInpPlS2TkQXJsBQvmEH/YstA9W78k2A5g5ZJDY+iCxkoREmCmctvx3LN12aZ34OBJys82yGsEA/wBhP8mvY7BR5tlHAwFhU2ZUwpQ8uZEzCbi074tbRaXfHTMFXlo75z4X0bDYbnnNdzU3i6ffHa7+/0ttm3+4g/mtol+GKbf56/vdL/5zemXt2CD/ce3L+ESAAj+8e1teaB3w7RJq42v/kqbgW2Y9kmV6tPvPu3e/SWe8/4O1O8XmfvnBXrshZkozU9vod46YkcEhwEnRxO94S7LNkAo56MH1odCo0d9AenbPloV/vIzamTgYzt0tnBkGyvdN83r0nrspa5t7fJlWogchiNvs5Ky1lC5aKHFwFeG7crwMfL0S5elCODIfxSwjqguLjfYSYCOlM6i3PMUbkE9YL/Me3MCUgL4hFZoG/x5GZRjTIyTdB7U2WlO8AqzzIT8SE4WzzrUfQUkCUsahn0BeChrmRmLCweGqrRaCr8Oh0rv6B6GBVA2xzri8VOLHeyzRmFCix0fcY0PWvX87iCIluf5OZOfTdeJ47vvHd9+5fjuve7tO/R+ZYH5EDsvC5TFBu2GRRiJTnvn6buIF0O+rm43DI3cxUINodRPOSCaNsw7sEhqVYyTcVoeuJLLghzC/Lockv2C5Hxy76rn6Cb9D7j94uknsVIpe66U46z3xazsDGdlvZDsYHqVd8+P85npzucP7bUUWPDUGAY9BHjSMzx2JvKLA8p+N0CLPiJ1zHHGeoF2HZYyghkBShgewuDm5OYYuWvNnbvd115wp6fD2iEdCAPUFh8lhc0REJsDbEq3PG6dY6lycMhVYvQmu6C5cLDJgBT1e+lA/HIT2IJGSMoH3gJjxL5wADPvRkd6KZiMaGVOnEwQBkH0+Ddfdl/63Fzakm1hmPsL8p13H3Uffk29q7u/epWd3tNDvL887v7+FRRjvYAnoaIC7feFkLIdz4s2iT8OxxwNLcMwEds7slPxVTUphc9Bh93aiBjhw3/lVyeP36Yn19TDhtqmRVQw3xoe93T89gfH39zD4NSTN7/r3rvTvfNaL4zYQPaG0EmIFAjvPIku2y5b6qABbTlD6eyqkclmRCua33vN2UlefnY/HMHs04z4kRUTFyFyBzWRCm3fTG898t0d3eHAkMe6IFFCpFv4v5cUduHJpbg8/cOf6SzbyJvH/ph+9d27L/ebWb6RA8/LZhen1ZaxhjEorFOnXzaDTMzWGCD8VKKxOO7Tkl4OumLsDsB6+uBPVhlywEILOOFk+5/rNkuFc2+ZyRbkphnrnJHcb8lFFCIwMNc8U+g6/eH3xOvws+PXP0PkEc7x5NGdk08/tAleVkblbSK7HZJfR4cUgiN2RkQmw3FGxFhP//lwsxFRiaVbtO14iHouClsvJi8M0AAiv7XrsmAIdgFSz21e5HPUd1+4+23b9E31kT004NxmAnYG7RbKCAz8Rg+ppCnbddg3tSL19qioUsPAeE88B5BwqeoSOZlUOEvcbqkqnm+GWBtpFU9IsKQEO3YJIYdxE+d8vH8CBoF1sTXSeFNtKQa5wJDdUEX4GG1MqZJ4cYPopIivfB9cseg1B74EnKO3kb1Bt+GPbv+eigHIyR8wciF0ePzmg7Pn3mJ7G9DKk0e/MJcLP6dEiuve+wVwg7MX7xy//jl3FfgS7+DEJXr23G16bffAOb2dPL57+sOL4ooWNla8Hwibg4Yc/ZhB4bjxvvwxdZDCK1yF/g/M/j0whIYrWyJYJ6Cw2ggFHUnU7+rkozvHH78H2xoVAiSLEeElo9+9QIEHIQGQByMSGaWJPmcQ4YCLXMUF2C41PW1IjNTZNaoum/1Ty7r97PAxIt6yxGcB6VlP4c46su13jdnMXCaxxM50q8qB+3ZN6MG+Z46wDSzqduO3K1EUOGHbGyG1+hofBvpKBfjCFAfIxQtoPDRDnB1fzh/K//b2fz4Keu38vVDQcwZi2JA5BJk0C2p63O88jm826rpql9NNwIY9wKcV0N5km7cw7QHdN3kRKME3gwi2dfFRnZM+xBNUG3TQNcZWsSQMcb9z1EDJ3FkfA13QuTZP59J7fjDBurbtHZfiE/LBtOt6Uy0Cd7JllCGXMzYazYJS3HkKLBAwQyQTH1nWvhGPYYQYT3AwBGuIjrH/WFquq8Q3AS9FZLdlkc0VBo12H2iwBjuvYkjWocol3elzEHIccyp13RSw7H4WFK0OpQ96JS4lYkW2mshkoHOGHEabUpj9zf7Ifk7OowxepHUAmZMgX0OE9O1AkgTeEqPZsFiB3DFDmZ5WV408iAB1wCf1bCBd6karXcSgtuKOT/7RPGB4JOb3nK16ycd6GqTDdF5mr+8RezItT2w9w+HxuPuKRlJQdGU1mxWwRhP2IP+h5f3ST0xzJn2zGYluSf8qhffHwj1Jj9r0fK5z5CDdrkz73kC/c1rTj1qkZ2cWLCC2fGPHR02Mui1pnddFGrQYHaSPxIBb5SUmJ/b+g2gxm/gJ152RTdKbVzUSCT9pa1S8gpbXtbyyqc5DPVM8gnUFdYLFFwPduGVc2SZCyHLoRkOrk5BQdyjo5kR8mGTrwrfASJRqvV3zEW9SXk6WQsH/eu7NS//vV7LfDEt1IJ6DbuKDX1iJx2fMPxs3x1C72cR4T3odAbUgW5hwqEzEfD4xyb46DuTo2N0zRNwOPYOaMXSc+O+VVDrjNoDwbOLaNZkdZJLb2Q9px2wiPSE+EuNzzdHSyFsxerVEbk7j38l13uIRDRkTlEheS+Xy08ur6VwmlcySEVNw0W8VicI2Xuu2Hk9M0s+APztdeWCTXo7m9/v9DD2C09hKCy/mI9oL0DHwaM0AfYjEcmg3YRvCs+GQtA46iIRHACDHNei1CxgegtU0oKRGDZY9H2dI1D8Qb4BtJ8ZooKRBKWcT++gzTvK5/zjxABuG58ogQ/vwSNGHTbJ0hD6vdjdpm1s9KLk/50BltucsUI577lACDHbX9bsC+JScUjmTlnCuioqulhvVko82ceBpLnWUxNXBZ89629cyyIl6kLQ14P1V5FNW6kekB7+LOExzyVtPHn1C/bBl8w5zdOWyHUH9rx6oD/c7Vnccqgun7Jf/58fsMfcxe/9TdvtRtWdPFzi+jvvPO9IMe1oNeh0FikfVtl3ex7b5gPTUp2/CyV/W/Ok8iusjNJgszAav1hTTzpguNNxbJaA1A4x2A6ITSYAsywHbuagHVZoOLKa/A8Y4a829SgP23qFDInVIly4dPVNV6tuTNyvB6fS/UiAmD1lubYcvCmc9nKVQWQYaEkIebPvYJGo9zPhoyxhiILSdpi5s5kKkpzksb7yRLcpjxKmVVHp2OY+cqFeR6cXl1ZnZxUQmSYsN2FjkRM8QeBPMTVpyS7QUmrfrCOPxMAfy207EUh75Jv+psMEL3N5+AW9OV8rGHreuXyCPmi2780XFbBmjB1/95vj+JyfvfCDbL40j2U+trOUkeeGEB2vtee89DZUdHo5d/K7788It+cRiqIDNZ0u8AlC48p5IEPzbxPlX3futZK0DTrmz1wX3Rw601Uvqfh698nzApD0xJthN/ikHr6faev4Xdh/MbRm/0O7z1BsQ83uwBwkT7JhhwoJpxrlNCXzOmRYV27UrHGI4Hal3eHT+ZnWhfciKq7RRQl019hqtHRLIbOZhtbl7uEnG2jeQ74RAHVND0M4QVhhiDQaxQfImhHWeQbMKij2T5mWjMrthDMvYM6N648N7gQnnzDb6pRFAknM1pSl0pF1MgI6FRAcFRa8TvQszGsBvKlvDD1yrtA6WkLfss2JJC+K0mJLD+aDzqy6xcR695BfCtWm0LBkRoQqf0ADXhMkEwZ5oTqy2XSk0WrpPJbICb5Vddgl7zU5P7PAq5FJlmjhMPNgR0xNs0twPUByNSCW1CjRTJsnZ8BdaRoMR4lMRjBL3hiAwWvgvOIz2UrrP1VWlVTggbXlyPpZ0ypbu1QRhwKU4IEBkeCFO25yspX9jDfybUKjQghWNLNIsZoa7MowjX6U/Q/Qf4HzQRHTYvjsLI46OxNGRA/4KjkRg0PCXY6Plmbbc2BvwGA7r/ZzxsFLuAbn3YYpyHv7UD+1+K/4uV0HT8UqjUU3uq8W20Wj5gAnnESS1pTOPoyZ8nnD4Qev86g/8GKopTV9VqRVKgKzmRF/2QvNXq0YJr3NvlJR6SGugiHqExhc6BgYguRPJCgMrUys9upfjJkuhEJgDvcId936dBt+htzYNyif3yfgDtpfcsUm3B7ULfIq1iKOk6jNIFGTR4nvyQihM+mWFJ1wX1ZDsJOz2Zt0zmsLRlNMGd+EgCTIkTgTOXKBElOobMNFP0PMU+BiXI6SALJ0YwsltLAQSv39zIhLesp012q6mZKM1DalOgUVIGNJPXLmAkIIvjareiYRivSQWWoLcj46e5yEmqWADUdNf/ALiTLxPB04ZJxqPRoaZKYCdU9BbB8jd33hN2ARZHaRAqV1rBiuwYtUW81nv2Q9A16QADpXUzhD64bk83AVvdubJ5u3Nzl3dn6336ZDOjrXQ6QCG5At5to/20N+fRgwyd16KIJ34tddU3OoEjsA925nJ2dvFnV9K4TD5Rn3PTDwbCvufkaI08Wv0SKIpYAefDdF//bLZZ+8obZ4wgLTbexxWMk0d+CJLaarV/P/B8mkFMZBz4ln9MoCFFr2hilGr/lTBa4eo0jm0j2+eHdyvVf3PFgAyhhl/3z7d/UH7xXKwpRz8dD+o1G4G4UEr4e+bMK1AtWX4XYbdqXoQZGdz9HuxVPdP/NTDOa4l/we7fJhCXzQP7X6q7CjAq7aReH5aaNfrB9jIBYHn7hTEzZsgdzOyxWWpMmxHdt6j87t8CauyJwZGE4woE3nrpg4d3ZH419ZGv8h8zLHDXMb++t7x/dumH3dnWEpINP0KZlkiPt/H7z46++TVs589Pvnzm1DKljGOWFEcas0/n2vJZlpjOZfEqx2c9947Rnw04EiYRM+veiZsosCLR1n9szMxKYEKULpb1jQlX/NqE7fse84QtgRqYOkpN/spWc7mdBAV1JLP0SrsicNbYtNMQyEKQKhdR150megNXFVBXmaBR/Jg+sXYON3thcWlp54qRE2ruwALCD1shrfI6hHzbBIssy3bNmYu4DBgWD62H7nysQ143iDuxlgfUxCJGqL2OIEUmc8GUNvWAM9uSLcaK2elhRzbCITkoWIYiprnChUmxBVAZDNPbyBkv63XuivmQWjLOhG25p3tBdabECF7nblM9SM3YjnqGYFjvq/CFNSLLAdODwHMvJ3H0ZAvzIymfAjUOSXAGw1IDmrAAxbWH4vAJPZiwTD8P1M+qK5NqQQNboLhzVRFyLxbGSh1kEHjW9SggyUtsMwQEeIw6UAM2xwug1ADQ6vYbphptlA7K4PEsLaYzGb59a7SGmlBkqiHupRNpyTp0H0D9ZF5EQk2I1NmTl3+qGMxybkBsh+w9u7dh6ff/xpD1Z578+y523Sf6H79JWbh+9M3mPz6pRfO3sJggCdfvwOFMVf8rU+73z538sUfut8K8d80psceD8sCQfAsovu7359+9+HxvftQjwJEnI3J2PkpGSny5Ie3T157k46QRpDJA24dGIRPwI8IszSEbqUNiXYBT2GJDvbs8W9PH7yP29nPvv7Hty8dMqAwMAwkS78tabWwrmhf3EJK4PRcC6LdXpxgQfGjg5yk3sViP2w8gB6nf5vXQnNpZpwJkyVg3l7FslNbkXqIFp681UOTQpJ2qHIBns+bBlY677EztwXuZ0OVMbwsMnyRRMSYpPtTkESe677/FnVbh4oSnpAK8+nOLMDI+fizP3bvf8yuLSAVQE7B6X3r51xgeR5dWkHBgl8YcDgUNZPlZqWzD18/e+/v//Xch/AfahTVNiw+y2fbvIMR5TuC3fMkOyED9D9pcnX55Ys8gA4Uky88ePX4pXuw4KEouToO1tukfqCHaA4Ot+um7VJMkqePDMkZIFff6cVuyU1wpI6Yqpw7dvHQge69V6ksORQdJmsamxTs2KRAIpuWPYfX/eqv6OEsUX1OMo88iG4qYTwn7Qk+IdM65Nyfel9NhMLlI6mmy37PjIDEDGPdrETC3sV9XcwYSGmLCMjHt7/H4KjH751++bfjt9+jydQpA+nFMWmWUjfvEhNYUkcvdhLo87qhVDy7vEg+2wHPZfH3V8w8bpTk4c3Zc+88efQLcofeg7eefHfn7Lm3upid9uPj1z4/+ehX5C4AJC+E170o/tcctC8cjBhzHjMWm/ka0bOfxi1PJDTYNc1cpBJML8URpSoa9iYd0l4Egup54Ehxfn6bGGr30r3uy+9gtPbjj04ef8YSodEsziSu15YYnCGEJFHa8r64BsWsKqgwk17hLY6cVqSgIJJ48xiJ5J/EskfeK8m2D5mDt4WxmMECmPz8o1dOHt9lcekPfjh74wFjvpQ8YSn1oDPmIGVaZQk59U/3hsyzX3AB1wLoYRKxtjsO7wOScOAfkJxH+45wWBYIzuOCLpwmY8DTmap3YhthbmgLwIORP9JQDsc0eef3Yejk9lr66DbQCvciy5jfjbpeejv8nOOXGYmGRcdMMga839nXwy5sz9hi5WcRkrawNC4kY0uvuEGnj6nDAROTw1CTt3WVp6spf98ZoM4ol+hMXCITwd9pTftzTcdnYFawWXHMooNM9/7nsIFQn4RL4gRiYrKabtJSz2CZ3vfTiva13onsrPGgqzvNUQFA0u4J0yM3eFFonNqVAzu2Rsx4YhoIBWv75L0HIHNbsYn0sjOowbJ53/rb2RufkRa6934hBkS57rxkNDzhytXXn0cKfIpzqbsPKaOiQU5PHr0PAqfJj7pvv2im52FR0Y9/ffz7+2LySvEaRLq7U8Hz7M173Ze+BFmTpuA4efnL4+eeR4HTGarY764QBqzIJs2AUFvuTJYX+3l+4dXzNCDZkU2TycBmUk2Aug84Ti5vUYopM7MrAh9/efoDSBKfgQgBkgNQT00taUqdGt8I6Xt6i3M5DfUv0QP9aCgm8f3xtmy7OOhQ8Ef3aPKIqBseOzLDHRCj4HRJr5lFye0/vzv+7cPT7x4c3/kD3YMpRVIJlopIeOMZzVX96A7Irhaq1CqDzXSg/zcxkNsE4cnjW0zFIbCYAsDxWz/DzGrEztp96X0Mmf3tw+69Dyk4NtIX3e+5Dvo0EQP2WTz7w8+P77+DBHAoFD2SzBg/GvKHwYnkLonTF/9G7oV5H8fAoX/y6DfHD++ab+haOf3hTRiq7RZf7aKxDZa9ysXVYL7dfEgY2lP6up/vt235hvdyFvz/mHv37jaqNG/0f3+KonrWihQk2wkhTfttrx6TGPB0SHJip3v6OBotxS7H6siSkeQEt1prJUCIA7lBcw2hQ2guGSCXpmlyJ2udjzJjyfZffIWzn8u+1q6SHJg5p993iFW1a9/3s5/r73FcfWP3ufqq5z2sSmZ7uwnKnebxB/Uh4xLg1FKd/LBBo4bA9aMTeyenxvbsAVjv38rwjAUM9pqbqTYrhtYMwSfhG1AchKDlcoDugd+qWCgaMb0E1jk4h81XMI6fnkDrgqcK/mz+3vtsTIB+Fj4SbU7s89iKPfjWGNUqznrwAmG7rj/6aO3amywQffSdulwoknXt2jm6dCR8oZNHQgEYKu1d/Vh5JiqWG0UMj1ZpA2SgEJhAhBwu6NNMk5JoN/JUkkyiLy2VIzCHTo4f+N3ErvEi4TX3YbZ8Out6hingHRR2NLw0QI1anq/xTvE3PfqhUKA5ri4dl3Pb04bqry/ETYjerpfm5sozRQiJLkLiwRKBYvPzzNSBseeem9iVoHq2dWiL5VlUUpSrRfFnxhyZLQmVZwU7Ols+gjhh6J5TptSqruKNZFeZm4Eh+VFrRnJHEfwvDVD3GDh9JhRSJEw4UrK2Vfn8cjGhxy/8YXJq/MDEWJaUa7B5ivOwfPVyiReWWD3xUSwqrsLouSwaASA7K6h4NDmOJhAf57gT1HGMtkHLD3Dps8Wq2Gis3cpmvZ4kCGqr/KcTJUtn1WBzDXjBSnmfeTJInj4HcKMXzxMSxNpHb3UufgOAK/88uXH6AiSXJEjSW39fu/+VqWYBC/WyB3ld/oF+bcfKtaWGCRXuoZxZa9smYcjDLpIV9ofET8Soc/vb9U+/VrSLaNbqoxvdd+4qgFVBuQTjt3b5zc7d7wkkwObbcKHwxgJQ+aaNfGonM+AOI6wn9z2ezAAtqnVxSqpo55XDwptZbXl3+6kPDOd9bmKQEhmIGZKF6InHzduv7bLqsbRexuaiBacTwHDLcvvTP56Vt/aK71NZssi/5cobb/SjrUDAS9Uj4gSh+9YoeFpKLA3LsjMjaA9q2tmMzrFSVj4AblHw77pZ5jf6ynQj55qImPhiJNDZayj0mOmSpDDccpEs6WxRoPyepPfm0QWjKeYO8yAUe1hFDotpOF6ebc77a5b92l5UBQVFbbUT20j8gGYNvI8ahOgIo8M4WmvBkON0xgrb2O2mErLNGo30TXLmpwW7NTUOmTLwD2vqtWXdS+WRKY7PD+ladI+pnMJrgQSCahIokaA1vqyvk/LSEffl3ucmnofuOo+sjkOn3fcqk5LHZz1xd0lr02zRKZIxDvjjJnCgmvJIUDh9g0JNHxmwgLZmZQIHDauemN/AguSnr3P6NKdBv8vCqq/sEo0cIvplxPhLcj2Bu9g4H5mEbeu7u+Gc2M/tU5OArwcSVDWqVFwfJKzPfePUyPc4Jk8xe93CdPDOjSB5D+tekrRO3kvtBB9RyBTUd6Uxaq1qV5DSbNwwz1KGV4clVHMh+iMUCPphzUW/WW5wEF7KIMbtvnHXwHZtbiwdbszUy5gvB7cBRusq66W6WzhssB4dF6wkgQszTCGJGfqJ5r7J0ANbW0jJuBltoyjZNPGFrbvzU07/0eEK4FAuYHYROpSxs+SVQsFNyE+BUrlW66A75C6XUGMumBWcozhtHkNy+phJPSCWFBXYNPvNSE5lcq1WL0lcV8Qo7bv4kvITu9RStSrxmpMlTXY+xeOD1J8OTRwPxjg+8dF79p0lLSgtOc40bWP5Tcbl0jzEDYMQG/Nql/K/XjMXjztm0Dft+Mq4/9to+XCtVJ+dAH+q+tJiM83GTxjWgzOVMmSqBa3qONYNcCV9BFRSWj9goHIGv13Vd7mfl0/h0lNySWA7g0tVTPa+UG5Ahp1i7ahnN/VOLxHbq+4o0jardnA292ziEA2ajUhzj6dn8J0We/f3c5WiqhhDK7FTKU3EFDWNZm1xk1oaZyLcI+Vv3XugvNKPN2jXfyh+jhOQIDvfewecuUh2ZvjJs+unv+q8ca178tPOZ+dW715RXjKm2YYTU4EtZOODb9dOft359EOy0SRp/zbRASHFU+ud81cMC5ZRqQM6o7Ifm2iUlF7YzUWscoWPhDK6x/YxBeekcJo8ZwrEqlZKhyMQ3VXeoqk/7B+fnLYsZgWPqRDgL41lkNWwPYqx50O/8Q3zgdMNMBe28NO2Ajy0YH30a44/4fynW4Akbym0wxhED5TOxLQYtgJW1KrTJ+o0he3gv15/28gpqWbe4hqz8UaXkbmtLSxKn16fa6PCrJK+iC36pB1MLw/tLRiOhdIhbyAGZEUuemjeFm0moOlbl6HzKUKH4n9qCV876lKyUImjQR5MwTImra+a6jNN6+Zr5ZmIZ4Jct8tgwmH/SQtyApjWpYXDYK4Ga3uONlCWVItLCwAgGmVUDduMnbZQqoMTdPjjgxXymwJDIKaJj5Zhd0kXUnIlCz3GrRa1DCZ42lwtqLOd4pbqupHKpRN9GOZEBeAc6vcN3ZzPpvVBiHcTj8j7Lb+zgUxsXKht+V8VMBjoNyG7aZLOAKaDf/56FE1dPN9+PTq/nDY+ywfbCqajn94tpHtcv3C5c+7d1TtvrF16rfvurc719737hqDu7BMU9xE7XqpXUQk5AwMryp8uB6OKNcqgcp4rA/hpJkQnGDH+56Pm/lKj8Xsq5eXpBHkDDwrZH9Oty/46NZksufTdX1n7+ibZbzcuXVx//wIdI9bXoiU1mJx8IeCCfzm3+vByj/uA9uBRQZIs3++QcGA5oXYcBxphlzsXXhHrAO4W6AvQ/eAmlZeuAVJVzHcFNRVadX54DazC4JJBTtTupleAkManVH2sqEQVB4SmxXkgBY1qOcdIyzovS86gSXDMxcjJhcNMu0Q1iO9cahQyVq6akbOnOzcuQXIKw/kBAngYxAf+a5s6JieLuyb2vzB+YLKQM35Y2CQIJoU98HLLyaD1Bu6qex7CyfnSbO04eqoECj4+eLbUiHbugAcbbwOgNu0r9k0fiDPX1pSleL10PzndOf06u+iJeld/eLPzxSvBU/+ePzgRADAxd+T0vbWvEW74xpnOqWvrN34QLMzqnXuCd61Gohd0+B0AZMMNqHPhK3CXUcvxwXlw/fniZPfvr7jQx0H3/e8RzFi0Br69FE+wev9zsW9dpGbH1Yv2kHVBhxzJ4DTy44MrqW42vpqM3oM3Bh0y9nyRPiIrloenjKKA9s7YTXJ2CqDIap2QQXLMjNWye6xMSGXYCBi2YAHBf3iNvH/Al/Sj74AAYMREj0CGGFq2ouufMxmRwxLbAvxWbvyTW/3gfPe90zQD5M0KhI7SH7x9lrYwLeL6qw9xHbH8g08EVbTXUNK0L17p/vUy05+zZzyA7t3zK92PX403I9pYe/fDtf+8Z9crSY7vuPGQJLK/cbTOqtrMY9br+LL7FXYnrTL0oZP9MrkWmSncdGd9eRlJv/S7125/mBRFU1TZsVHtVkoEapRpbZp2UWyAUYRdF5tuVPyf5UyiesNptaUbscuIl6tH+a7ie0oyUbGJWvv2g/XvvgM57N3vaPNs/OUHsc3UpKlL09zEmu0KbAdAjkShvZ2Qr8hwXONs7IjpJo3i1aPM4jjObWCCvfl6Z+XrwCcmSPEg6xGXaNb9zpXmTUSO1SDh0Bcg4yS4eiNDj5Qipyh7WykzZFkhphUYXkR1RqfwiPmiWUfbOMjiYFE6DPOk67O1ub1hvx3xD++JOB3kPqIf6VmmM52L55V3JVn6wfOM7q7/6+DErv8+cXLj1WudldeBhKxA0vD1m9c3rvwDvfu+6v7zwvqXK2sP39q4+k8IxyAyPTYBVw/4f55aSbrMQnRk+0q83rh6F/z+Hv6985dzwQvSpPbjgwtTonm8OdFt9dTn4t4k+unSOhw2eH8U0q4auCi1X2xAvqPgJIiXUOfiTdH1zt3vu/98c/3mu/qOkZmuenj5hmv33xKMEftOcKfNae3cel2lQkFtyedUdvX+OYjyO/No/eFDjGMgH1f6SI9UhhaiYyEFlCtPy0AMgb4Clcll8MWEHqCP4MYX74EHIQ4KPWbB85G+hAW7c07Miui3WC+TODgLxsyx2CuWo6LhbLl65x3y390QN9OdE+unv+uegXHRtBoeneyOqO9i74hAOBVkHmj82dX7p0Tz2hcYPZ2BAf3oHky4/iR+KRt+nSnec0afNICefBjzlUuCVPE41NDIyAXl6n3B5JlAAOwDuzOQDsZx1ZhE9bMDl8BgZQg20o8mivnKWP5pC4QunMDec3IMzcyHQMSBMNLlYl4rgLyTCRdK1aUSqk/NNBpMU1BMCrMaQAFbj7H2HrCKBXa8o/ZH7EOeM5fKe1N6+HdiCpMGHk+vFRLqT8ZW6El1v50CD+vuJbH0MwZDKLWoee85M2JJUsPdLFNNWcOIx2rexxU8y5soVo/80g6GI1pgpDDpnOetDwTu8jW6GmI3nrGRAb3C4+/luBTZWOfyqc8t/fJXRJJJacz0nUnueSOMTNA9ca3EnPM3Y9hVnYvzO9SHAJ3wVbE2xt5iX7hd16lR61fdQAwqwvgI8fF7Y1GleX5UfaC1tvb21EVIW6vVr1aWLwxDvf0tkY3Q4dU0e8TsOGwL9gdeAb7CFECspFWzUbNURoFxei4kfilo2S1jIC6yMK0ttKZb7Oa3iOt5C7e8heJetrTDQiycJYmvNPoh/cfnQmIxE3lLrlfOnOFz36NeI07A83E79EVVtnoq69tB8P/cDshnw1jpeHUhRRY9CdFF8AUHm3E3szHGcyGqLlm3iowZoqDochVyAzSby5bcELsX12/ehlxLWm8H2czO/AXCGJlgIDW+cVX81+AcVI4AqWoybBDwoNDbw7bgAvqU04F8oKenVkRnSRMbbEMLx9ODAZ3d9TdeWXvlLnVUjIG2o+SQ0Mf0i5N0/kGDiIXT4RtirMnMUr0u+ik9Tj3esD5Fw6FqfCIdBU86seVmnU9ECcR21oEZspzCYZcPDCz2eMKkKjRXlBYvcdC//NvGh58Fpk2J2iq0gf2nsdA8IqnhjhBtoY9JK6mYby5sdx8xQYh2xZgBpXIH5icm2mdCxWQBwwOMHLbUvX1fEAZwkRass+SqBXvkqQDuZmSW6J6k7tLAxAgxyCsYAjowFFDYor+aegRzBxUJ8WXty/ssdKzcUm7N8lbxfU1edwRHZ65CG6QgMqoa0dUpo5mpLaIRDb5Y+X7tPOQ1lcv0YY+uFOKBuWplEl0ljCtZ4wNrx17edoPQL+dIsKyMZEMbygTJE8RvWt3PBWUBA0dOPnSsS8qqZJ7y47Ky5hSSx4JZ4tS2iQ9JZQJK4ExBp+vbX7BfaGJzcnBenwSuP9X7JMYoxBmGnuKFr23lDvhYjauVnaYxFDRTkhIyzAweqjPWb3y68cEporhoZGn1YOC0X6lss+0JftbZO7sfPYJ4xjv3QnOq3a1DXQo9nQbLGNI+mY8zdqtLtx11p4NGoo8QdL7cuCP+mZe6KrSxMUQdkU4iJ7jPKHwTHDBQRSPIOW1HKhM3GfRcVsYDGJX0W5yphK2vjqW516ctO3f8RMqDHjvHBe8WlegEj7VD6WN1hZkXF74ppB0o6lViyWRGj74wtkSYTc56LEkQXjz+4VEyBxREbdHRCQLxcKZexz/XIIZXHcmDsF2gb6pJFgxsqTF5U5mfkkmffzyh5ZW4RJtMWHjywW/HEXf7GbtsPTlpelJIlOEy6uWxfBvBIWbgAIUhlmA03ARd4yG3yXbeWbktqqCqH+Msx7YZsxZJG60Sn/uBtDG3zBPWDjq3Xk/gT5L7bhBZyWDalTqsJah+75wS5bRm9tHHnesfoI0OLVGo1YqR4XR3zF63fPf85913vu9e/2wTl7tzwVcF58ypRGB47T6Rnn/KrevdAsybJjff/zb4mbeC74oe6dkwtITXvCWZSPYAdDvi3lSbKLl1I+c38uxh4tSp5FXAVYe9drXoX+KWlmyFYMe9vY/tYnDA0Az1aPIsSeJ+5gRAceFexeuagQ7h8KTMh3cHcpWM0ET5zR9cWrtyvXsJcjeLJ/HKymnug37P+p9CkzdH7wyotb5IT7L45Z/FZHJjtEzUK0hkLGPn3ctPaJe0zuVrnRufdldugzeScXuAHwLeR+qGWvvylr/fEgCbliSVN2VDAnGogBNzcf3qWdDk3nodlMl33ux+cxWild+4BpZGdBR2AF8ez2m6BzQgOphtBhqQuxELXRhJ0Nvc/rZz4b3u9yumo1+/ymdOwbU0R1lVwjyr8yDilQIa4A+ImE9MfZUzg0KxKaouJBUPVGBHPLUErz2i3YzzLSrfJiJHXSEcTOSV42y7Jk52FNpjBFM76k6Sr7yOyvmWyzRKwKjO2XudH04RX7qlnZcZBM0MhNCKTICAXg/GPFn5WNVKWB4Vlt6USkAUIP6loESBxCCKaKqxDJFx8EPA5tnxjMQehriC1EytxXxogYlxJakOmUKwfnCCJMLue6fRF/WkdEo9Sci18AeoOE+K89lZeXvt3qPuynuCfIsya99ArntCIIWegnoIn8YsQtSXmHHTnGTmjGz4RrgR6PmgUdYfesYo1uYGLygnFk9LZo0GMhFiBHGJZVOTrNW2SccpptcnUrf+6CGYGnCuBXWR9cDmBCqIzoJbPHp8sLRfvkYXB23ii+epLrlWr5BPR+fq10GtdhSEAEmuxV3b/eCHtc/ugUCh/C/yaz+c73z0sPvdR92Pz6xd+T4vvvL7mKHDAHlkwXKTnztsXvTV+orqNroGigVDwKd+yB5IxC0xgrfPBnnfLehTnCfGcfW90uyNQMZA6pO1GNPK7awAbgbxy+1wPSodTU+2571b9FSKV56bhA6CGTtk781NYWpgqvhEMIOsji7v5dvAlhG8Bi0B9caZ9b+dgpV//RxtV5MtoLncBKSGuhgh7ujGpdW7Z+LVGXVt4tz1RVks/2RZd3LlqJroI61kTAfHxFWcim++6FxcIeaapi/OSTm6cHmV9NesN5UlpCFNTOzpGpEb/RijHstu7oChJAA59BsLTSgA/ZCIx4gG9sW5UoP+0L3kGNZsj4BonIX+ozfxpBrcp8zHSjmqiUNCY2lPW6kEHXddDVRKO2MDcjt+ptkkqXRugdL/8CZyz/id70KTJ4LEGAovjIsgnfNXTB1WnCuTQpvFmKmEvRbousmYcQkxRbLsaDAdDoeFGD+Wsfnh5hLgNGmmM8vQ0qDzaciEKxQ/lR0JVGp2GculF0TGcGHFEMGlkshD+grslVwZWfuc7C48pH6nsXRzRljatv868ZeWBpYnCfXehc6F20DKCdcRf6osBRuX3uk8OKF9RbcF24Ongh0xdo4mxAbA5w5PYx8L3n7LtRRFaw19PGmD2lQa0YCil8uNphmoCNnko+osarcn9v9uZ3Hf3j1/KMLCTDrJfy0aVV48tlP6rRwY37XvxRfH9+4e300funymECjgtmQVjmoxzrQbL9PqmFlqiKMfWje2UQ6Fl0YymAJtdvJj9B2BWFXxJANwkXAt/YQIi1sZtEB455PfA8FZmvZf2jd9orHiRa+qZB9jwIfX2ibBrpLg37n7PQTTnL8F/hkJimwrTpK8RnyBknEh1I6ZtP134BiHzXrtj6VqOIKBlOC2+ySG3HROPejcuNv57LQ4KODaBK7lAOPCBSl8mn3gCcMfnUCxaEpIQXikvjjDdcjcJE8GRw7s3xU8v1SFr9u4mWmIYZiKrRwL36RhueqfJD47NWdhrz3IbDbj+RsbRAyM0598dkmsdYywAB1CSYP0I+ztm6jvTd/JaV6a6Tz95vj6Xry90w+ilfpS4MtA7051J4PMzqMzPJ2JBHrF0AhymHogB3UAenSkNLNctAknfLZn/PmxXUw5IWS1FVKysZcxuKCdwCJ7qgPmmL+SNxdzo5TQs+B1fRoszc5m+LOsjzA2GgjNlPJxo+H/Eivt9bHb8uMslaVWTuv6pivnOM7AKGVMuXURm3eQvFsB/kderXOlhXKlrHlztb+UeqXHnYnCD+RZkh8Ozpbn5iIx8pko41zBqaom8oo/9273k5WNV6+tPfxWeWdB1ppJIKcBO9Bv2xbYCZuAJFKMWOfiWVANG/EH5qgBaKRWl7BeCmHEVinVKvIQKIAPu3hWJVuOEkryMRPnRlRmcpj4zYjP5/jwUmPZRkPl6DVumlEhgz+LqwxZchgMIFjIIv1BpGIZDH8zS3ImLuxdDlS1o5wHeLFUro8EGfhnelsBwf3pB+Qsy1qqNaiziOm6UBCvI7h+dtBIzJkPHXCG5QwQSU4o8utRwh7/tcy9jCEP/NJEJoeZ0lrdXjqLuZCMLMSiQICMmuLBpcVF0Lu2xSPRVzTuAVbouU9o82ycfqP7zg8Uhg0Aqa8rKGML1tK56+RBwPQ+Yp0MMG6kwcZvhQzWtzJHbsEkzYmm/X5YOkPk5rb7kesNIg+Ad9ZwTIce66182FOnRJrAlfcss3x/qK0+sFZle4dzKWkw52NURIozuINxAZl+q6xBwOzrVqOnxcinJiXUflzT1dq6VRcKreURLN50n5eKNOVaBwkH4vqciyHUkT7Fq949/tz4gQNSvolXT+GQhhZA+lQNxLxzqJVEDSzf8QbIrXrmc9u0XTdFX5CbHNwL4uliSazHctRgbKatW1tzIfq6t5EAijlEVFxznLJ77awX6cstlugOxipDWQ4XLSaOIgSCB2ivx51jw83hSircQTDn2WijitFGtsp4Zy9UDLrartenio7EVBuIh3KDQwbhMigJxQRkst5OG/sgoDSg6W0lad5itQp+Y7Z2dCl0N6at96RCxaV6OfRBaXM7gqqVwHV3MwOj+IMGLD0qMJwiBgW1cTL7g92MH7t2/4jLehdpdOT4taJg7Bcr4vAILrBJlxXsRFN1ygA3o2GowFGk2mE02L/vwFRx/4F9U/t27dvDMRcSiATHTvkNwMSLIfb4M8bly1G7a6xBNgzeEjnbhgGG3cja6VSdPkElBWZwoFcyVXESp+QPvlKNjZjAB6oyLzuW9XDJBkhyvTx7JDK3JVYIEgbPTqxsQSVpU7BkwL1Z/XMNDrqS+RpJNhbIGPNmkjFz2tWfFLzDrgOeZMao48lgmx427puYJEOET281Y48h7IIjoojh1BaoJLyEZPfsw6DXn+N+Dozt3b3vxSKs/6Sh+hAX2tjBPVPWa6VMVP0oVqNotsFYoub+l7ueQHicjStb0SGauMETIjQt0B0trBEhi5XGqph0Tx7cve+3B60hEAIBlHli1EPySHFIt1/WdVbAdhfKUX0p1NVwUy9OjB84WNwzMTk1vpdaUlNVX8CcKYo+m/KMTJgoMYc5eVwvk4JjiuxzMfyMBFsxRnvTNPcqxk7LEDxrPc1rJgafSrO+WFu0LhrXGBIvZa6NWVqdEAIrjskR8fOiyDrKUz+bpECIvx6+zFotgwekD1h8lOYkk+GPq1TizD4LU4/P3Zun6lglAi0IwXQYKRRiiPkqGx3CY+zY8VTYq59OJuheqZ3BC4OiBHcGnZXTnY/+ytmQEQlCyI4UyuMChhlEx7+f9TVvbIleogWt4wg+hT/p4xFsqa15DAWM7j+7cYkxlaBZIHwuvfGQtkSJwXN+UHyoOdjJCakY+z6IcUBb0jb0x1banYVC0EmyCRf5KQLixD0KfEi1mxHGdaBBv4yh/svJnoGbKptmoNmsldy415TiDZqM02iaBukztxn7AZuZbn8LKdNPnaNDpVyKlF3Bg3dke+HF7ASGNk662Sl9wRMQ2YpcKT2ZHi70Umd73WcoYZ1EoUgbiCYTDL1lNC31lEUvy2Lw6CYjr7gqH0eftdOmNGR802YYLiMrCiIF3Pig+97djUsXupfvrZ99tfPRd6GPhkj3dyxNSD2+0szKUGFOQLbx9QerD3neQguE4VC15caJtwNGl2RYxZacv/aQ0gg2DNgoQ1mCQ3XIlmyJkNkIDYX2J2mv+QKgxlpWJdwfs1mwg9Hy/+e9jfe/7b7/vdiydpJO7o5LPqRnPsWKXjxPLtRxT3q6tlbvvUUIhGv3X8NGzm5cPgGu1ffe2vj40+7Hj7rv/LB+9ay4fN27ykKonAtViWC6RUveDlp6+wyiwNAG/wLrYW0R4E/byqxHu0P8lICwBR+aD7XtQMGaeB3RcXkS/KwUabzlgtt4HZ6NorgUcnE39wqBHcsGfVuHONpZH99lLKN92fI3LryUwgsXEuyCuAmiuiyZk81Mh7IMpPmG2kZt7tdw5Y/5znTOvbv25jedmw8AZkvSHYL7UUwYvTWTczY8uw9V7N3rn7Ey9/3vxQZkzDN7K7kOvharJu8GVqEqE1RSULNx29ssn3vR25TdoZbMRyIzKzi6mL9wrFwP6YPL5YjTVJnd0QHP6iXURH8qRY0QvprLclL+p3E3AofLJcw6ghRz3RBBTmJ+m6+9dFEv0XcULXOO+Y7bd+89y93AUOtX0GcxvnEs0OGMJ2/E+L7nKNwj6c6XjaTl34pv/m9hn3PQijGFvty/P5f01ms5FPeOAluqcPREf4PtS06iXfMTxDsT3sEv1STZEdoeH197jxgRX66Nxk75NRpk5BnOWiFy2p7xhEdwJt4k83gmNg9Hb/R3M1y9nbnKuurM3WnebjxPAI6qWzUhOa06e19SZmydnrvYRcWTbCGK9XNPdd//sudVpVV/DaKj/0PQRTFEoHSon1S3dyWR+0jrY+0qzQ7HO4o4ZUyO0QmUJTLB08Avw5nV46h7qMrS1sr761evBcE0iV0FhkjqvH2WUn+Edp7Mn8kpD2YEaWOohhDGeWQNQ+ZD5NDQDCGAYKnYFI79MqtTM+4mR+hXaayNSYR5izFq0GqLmcgtQ1tSRDMKq8OGfD0gpys1EPShBB8YCGSGAy6OC3Fg5CHTPXsm2B+QvBD2qZL1j1z5Fk5L58KCdC5EYLEWrVO7JcfdlgF47RZ12txZMedCtdXWvvkGxObrnwcBh89jQOahahDsFrt45RMI38ftCI/GJChMMBQQX6rf7Q944JTmlqYFXgwHLH9swhtSRXhL7YT0q6bubbxzI5jePTQ2tH9o2JJqYolKHOUQICIBSDECPkFu8BCdeIbDhBh/v7uim4NEd2r3f584OSb+D/MRBMPgZG9oTijOluabvvSGYZd0UPRw2Bdyk/3RYuhLTpuqKuovrJy9OkbNxkrOgZFZd2h7hK4zSEhbKkzejffO4m6k+TFnz8Vb60uvNceKrfUvTvLxiWuzEtxiPeqtvt1hvdNnWHdibiNqNKLqjE1rkY2kOSz4epGYls4PLNA5dQ3gpz97bfXeedKhG5mkNgMvgHgJiiYh5qHY+awHcwV/a7Dc4/ikIuAdvwx+basJE8cHLPHtf6w/Oh0fkwL/8J4zdhr0Bs4r8HHYraD6eXCJkC8BZPveRxoXD4ld5+73q/fPE0+19uV98YlokAV3lNdZjjl/hdUfMimAf9IFs1cDk7oRHzbdz4T6LtaCPx2d3UA69EFri1hXvkTdL7Nx1JcLb3hhXlbvXgHNmZwdwjI3gCB3BATmkQh0YG2OUcoPZGm6k/b/dYDWFnuV2qb9z9AYUiqmTBm0gMBgIRfHyYIQTdwF2003lViqm00tv4yBtiDXCaCbMBl+fHCFoBsEn6wQ8b0QHz7bip+s+1wteaa1pyVNtZty1R0x3oRmAjtH4qBc8MQ8MbKco5mIuVYp45Ep5qC1sbzYBGa+ESaf3y88ylkAbT/9lVhjlUsPPCRPiSP8Hqlo1798rbPyIcM6XYT7aP3Wq913v+vcvAuL4LE0/v8LG6NP/YzBTLDqEBMbmqIRh3+OGhILZ8Oi1Oxho1oOR+TyzNYWSuUqyKBh42h5MT8T1Zv5Y1G9PLcsCqH7RpuRZ1EISxPHGlGzybSvpXpseOWhDRZTgmh05BHtglNUD6E3pcoiBBaJF0+FhbYOCwqbS+UZs6qlpbJRDbwt4qOCtxl8bzQUp0J2yzkMDj8SNeCE5eEs1muVSlSHMKTDh+vsTp6vR5XSch5w2+EF5UsOzV6TvWYEY6ZK1Qa7aIZTu/ZLj/SRgDw5Q5l/RXcaPy6q575e+8ZKn1mzurBUaZYXK9HLYp1EQfJ8efHgnqmJ/XvG/31i7/PeqgVdmW3Ml45GcoT03Qtje3dPvjD22/Hii2KvmaOV9vCAbb9yZ2Q8Xju4gTFHV9YASQ1L1WVIO5K6Z6iMPUI9lWaHSLUC029vF3yu98uckEXEy99NTE7s2wsJDqOmqPgorJQRO8Ar5Zsp6jIvJGXU5KU0lUp0ZmBr4eDzc2JuojrSEGhqZr5eE994G2CdeL62SE4NISVryB+NlvWopOKc3tHhnhc7Lm8OXRbCN0WYgLa1hFB9QycPc9aQl6ptHXzDkU4I/Sw4twglCjAJAYpm4fBiox3Af8PeucmBYVKf5/ArZWKOeRfKZOhimVrtrJNwHTTEHHaltcOGIkqNgAoVKLwRksiMGBYMe/NQ6JTaPMZmeVlm1DH2Q/po7c0SJ86aKG1PJdY9t6hNMmaORs18VJ2pzRJBCF+Gr2Vgm9xlNFBFuHgHqFhsGQbaY2a5VIF02UlnmkrZZzrtGOpeYHRojz5gmb4WF0p61xar2MTS2ivLFoLiC/smp3oSgP7XMm0pocOaXuAv6FJ5Jsrb2w2HzK+sOzdlWPLr5Ig4zQqq7Zxe8c9H4mhABn1Te8UOI5C8DThqyTfFekSUJ27MSyV3MW1oYzTMSf9d6Al5EG9FhrxBoVz0N2Zblq0zX4eFVQCdPXFbt7bC+dpiHl3Bj5UqJi9lujOr9+aSsisNhiyNGmjvrZD3hIGSAZudDgtHVttL713YkDkcnysORKsQwkF7wA1AyUmsCVSw0Dz7QgR4yfB77XcrpI+6OM34MURIFvmBxyKLoUqoJoZIy9DIeC0rIeUXxKeHdoZqCAtdLNVLTZIUGN+MJowD3QtJgX4449LvVk22kaGa+tVuqSbaCk1OrwO3Yi4F9zrpbCWsh+wukOLGUf2eZg8ewSvRAjAv4vWOxPotFlbcTfobGpFU87Zt12yYDhZlFspHwOSB0DuVIh0+QUTspVNIEZBrHKCbFjDNOkE3qePtVmHHWstMdlCRD+yJvKlGVRFE3wHUv4wkr6PhUnMu/0xoxXMequKHI4eqYXZ6u1biqD2InhKDgtbPAjZdPcz8ZiH7H8HWfDCxP79rYveBXGb60Oxg4cns0FPbc7snDozvmspVa0K2aNQqx6J/EcuNDWRdj4zYaOGCw/RNNuKI6oiKBaDJK/JAk+RHxBZpVEuLgpRaCbjrtaUmaZeP/Km8ODgLwdWL0ETmMOaXHTy8cwc8nI0yB8RyCfGiOLl3bP/kC/um0PGEq5SeLBx7yE+z2UH+Vk42bxyKH7Md7s2Dr6+j2MTkxDfOQqPxSS9Bq7zIdQ3CyR+jv+XUZdvepRErbuXOhmp5w/EUuRI8jUHSAfhAsanypdFNNc381yA73Fh7Thw74xeodkOp/6MK0XKIlf4i+LfJfXsDkHaCGRBnZyjGsFQXZ6PSqAV/GHtxz2AwNS8W5mgUCaa7OR/J2LFIsOQRdFschuX8XD2KBq27JFEjYbmb4uu+hghBazOVpdkoLxrPg0sA5KsJmoLS0KhTCwRBtLAomIk58e6w4JGAA/s3sXpwSFXuTsqoE6pPpwswg2ZP2ZlBi0eyLE+1+IcmW/Qmj4r1PzZq1cHZpQVBv6CGnAydKzVmyuVR5NU5VQ9mhWNSmOXKeK4EBxWg0uzYTjViOjlAnudLDWSyJFaV67GdgOgTWkiexph+EbAjqSBRUV4QY/HPrIVeZm50cWdBre3QVHK8HM3mMfAh+OUzvxo+VBWzXjuer5RA9oMhH6qCBmEEj8ihaqV2JF+JjkWVEZlx3WwgZLI0AquIWzivrDdyMlThJ9VCPim3EL7LDiLNNoiIEQUlxFuxIuCYrgEflAu73LW0SYnF0ZZtyfIMmMEj9uU6MMCRxwG6vlM4IOTxUqjmormZ+WghGiXocnhXqwNXW6tWlkdZnpurl46AZx0H+iIPCXmn6+VZ+SEoFUy6DP/j7Ov4D0jR2F/LYYq4HShgUyf+ci6cbsGf7ULoXmWyXtD3Wn2mDSZ2Bn440rI6q4NlMEDR2DgarfcXcHReWqpJzC8qKuapNIfxmNCknJCYFZ53NKCl47QGHITZHhkawgRq7X9t8QjaQ79pLdUrvDckiKRmtWjtWIGmWI5wHs+H8oZosI4NLlwrAYZ6jF20iyq3S7XTVHx5Q4ZQkLLcrFA+N6QQ/f2o8cPkSH4hGJHhApCU2LyqCvXcUiZFOAzJClzcycaTXIL6VmqZadsBR1htRDOYAygYdiVLe0v/bNJSNq40pu7jD3GwtrTiSmOxaf2a4vYWp9exIbKKBtTGlta4yFpjW2VcRJVx0VEZYzWCZBat+cp6FMk0FPpljsXVFesBuepgz4h4q4vqra2fU+IDnV+5lXNIo9HfWymz3QzHvTXOm9cvGzMBPJ1DN4lOKrJJV63mJ4Z+A7MM/9mWTVFZww3g0UbTtPPPXIoiOv0EZD26aapaqqO8CupWKChWfZmiwmHXCJpPUqCoWUwAPGPNiCktotLMmT1X1U299Wqp5xZtpdTi4aMpihinnUYPnXM2TeeMUyJnkPce+Jyr6WnYky5pmyhiKaj7MF71UBAjXTS1w7RaUtHr1Qi3rKnoY+loT6llU1rkJEKzPXQ1Qn5NrS7VVv742b60tzxsQ3XLJJQe5FK0tq20obEa1xyYoahP1uRyf5Qal3rDKlmf5nbTa+A5PlLjK2n1kaWqM/Eha033puhT1XAdFbB9uuxq00+ac7gcbadv0ZlVTJcSLAUNQ3nQvCdi5pqaOSzalojd9XIP/jpup+aWUYHRP5s+iLG2iGbBCSMA6uJw7WUnIrSHcZwH5BrxiomGGYOsG9Zy0YFytSyRe5Ks4X2YwR0bqG0V95nFf357+GNzMn33Xdt6+zTyUmnx35/BxkuWk2LccpJs31VDsjeH9/JckiOL7Sy/0SfV7KKok7dCIgzFdDtJb6MrUzRJSFINxjGLcStciAQ3Bp9NThYn9lL2+F0T+18YP+DdgNYN3jYvbeMM+Q3LQtBTxuF2EU3KI2gj7muMP59tuU/uIu2etcZqGkr7tJDqA9HHJWo19rgW0c0cm/8dwyGeT8O5phW7wPkuLv4Es6dFBKyJ5HDIaXxdiBEH69bv8xD+L573Xoc/Zkpt2wZEPdkG/x7akFYNjlcnTVjYLB1RdkZW8/RjWTQ3UdFv1eLatm6VFsS2AcilvNQI6k4uoGlkxC7rk1P4eczGOFfTwwXG4zAGoC06C6I7C0sLCB26UHoZ/mb40B6m3WyqwRFalXEsut3G6DToyjA0fQSiUtqUEMlAt+qlZEnZX2b/RsHxh4bWdnCIeZS2ClJ2ejo0aymKsiFntOLP2g1LmW0wWuUq6YmA49CbEzXUodp8rLEuox0BGM4I5YJt2385OCz+3zb9WO40UGu3jVGH0rcWGsqYxwBV1bW60dh+CGeE3+Y309VpfM98tbIECEIUbKW/EqaYY5XYNjFdANuB0QGV51w2zw+s3oOqPELqMgeJNXQv2071rZBUnzibPLfuBFKICQlRf6Sm1IXuSeIGmqVNyQWl46CDZe0g6D3JVoITBz/F1PWWN7JxiwC54UolfsvUtWnb8kiasdRUYpCFv/ky7BbRZfdNnk2jVEDbSblT4gtYx8MwMJO3EhQrL4SZQTArie/gHzJJp4k58bGa/BVifaH5v3f8Ok8POwbQjMBJdOZE3Iky6j+G6CpdDdqWOZAPLtfP28QLH832/1K5zrb5l5eL3oLp1DphgFjvoJhQsMf6VM8SNzpJBe3SfWt4WLtMzGL3XJDUetnpED+De9UMADVyG5jBDyphYczNRuEyDqTAvWa2+mYm50BQxuG0fbGZ6qak0ElQRg1vi28mGp60fkNU3snVu19sfHVW/PHjgxUYXH54G2WOeGY4R+oie0a5Dv+cxrfNL4Kp+QiupEWwMuPKgteBXDRxiR+OxACjYGLv/oNTQbOGFm80+R3cvR9Vj4Nm89MZGzWcpqeY84CJp653IWUAxcPLBKi87HjAlBdKdfBc2tlvDpcdBEUkhlQXn+3A8FlZC1SDhXZapswWFxiRwKNJ8yt2ClZMBdkp1HR58TtiDeh4EXpuGLbI94gCiTPJDku4KWwAv2nudWFwttyYKdVnM7oyO/TacBjxdEFXuDPJMWxHgYBLnfoNxC+5ORPPgvKBasrzK7NXFMGzN5SbQ7DTVYhtF3cepL6KGpC4FjBFG0sLsqolwfbNiPdwD+fzuP/gz1FotmE8zOOWd17N7WlMmrdNXpRq1pFVeYq+FZdLVZyTfLO8EAmWAR5ue5peCU4MH8Ov7TuGxT/YzTAPHYDOcnqAmeYSZjSbLzXmK+XDg0JO2P70zgyUsPKbZQfno5dny6BystNRzS+UZgbBwwi0gVyAao1NRxL0/XunV+9/D6D3ky+M5UXrQfeTq4LsdD77+/p3n//44FILe4Mo2qGGC65E4paWLdajxVqjLBi75VzAPm65QIjikE1YSBCLam2FGFptgNUYnoKnGldEV3i/qzYHK2OtyPZNrcjOYWNh50KseGRoqLRYHjxSbs4vHYYZHcJBDbX02NpD3NvGkOAexSseKjoh4srKAdISCdEC4LnR6QW2aiMj3xvecwbQMFDBZZTAxIdEvXAOYy5akNIFynKiQZClMZIQS9sHdqHUnJlnH7ulSgV/Zuoh7bORzHQpPzec/1WhtXNHOxvmzGppaUnlEMZj2rCmpKBueju9rTCQsOmeLzdfWDost1HQvfxV98LF1R8+AuwB3H2YhAHH0w66b32w/sVJE7MjhtgNSN1O0lcuMiMuMHwdx3JNASmCQWcSkB5daGV+x8qFbCJwEDRHKJeDSNKsDMU4VJTiqLq8YNiXXs63oOftQSF7Dh75k+nUsVgDtp+qy49N7pqYGOJh2akQ4Zyhv+aU+KNWF9fAbrzcxXbOYNTerPzp5EOE8zka7C815zOqiAe6voGyuIcc5CSi5+/GD5BS2aQHdtwmwKwfM6gClrRTFUhqr0+rcVLxjBqnU5Yeatl9aA/xlgL7ODVqUEkb1AEnr1THuastQoiu/CCsj4i1wMkDfV/piCdwFjfmMob0YwnYKQsR4F/I/ZKcBJ2+HSw3fPlWkwFoaKiM7dE5e6rz+qm1B/c6t95C6MEvEbEPKL0/LhnHKzsr6FJdXCLYPvWG82YKsrXg74+dmRK7kuMPkNgBRMtw7ZdPP+0eYX0+qWKmqbCpxEUACWmBuB4LASZoEYD42ZUBl036MTSas4LcwwTCB9p92fKG4rdyM8jjzw3qYR0TJKVUNdgJ0Rf8cGxycnxqcho6W/AcXBL75MHlWtr5ltlo2zrGP+mE6lPjHNLHOEAvRs3SrqXD0b8P0SB8R8kaRv8HSZ2EeC95xuyQN2sj0ce5mCc1t2mzSGqDOWfKt+iwt2Tl8d0lN1QfiQ7nwtU7b64/fAj31Ys4nGDtzEr38jerd84H9pwFq3fOrd45sX76u/gRtEZNm57JgDlEa4T9HRQ5lE2dAM8ocSiIkaCGJ/67/tol8d/OR/cgYTc+7zFmKdg5mUSM6xv96nEeWHlDwxjxKTD6QxnUl7BxoF/4w+TU+IGJsfihZiosCxjERPAEDp+uCiXy6uCyKJv13fZyNNZ9v1kKAQUcOU0cNnnm8MJ9DKLwwvJeCvBrDMleeuhCaXFxqKVmM04f/Hpa6F8SxbDOgqw5h58kn4Z4ruteKTbE9JjpOkhyDv5sPyTt1p8pe50N36VcK1LSrXmzZahcKAkmBVdppvKxIeFKTrVhBL/EU4aQ2ZTU9Z5kGlO79g8d3L0ftGaWcTWaEcenMdisHY2qRbGtM9t3sDYj1hK7OEBLcGLlqphH2TgAvjUu7tq397mJ5xHCHvEAZ4vazmIocrMusjhRlV5fcWoKfMRiGYlg3uI5SNrKM9vzFIoFG0W6t3tsagyhGOfKL4/qw40bPR96DiulBnePqp5WQzCOzRt9m+MhmTCijaVKky8GfYCEEDxbbsC05WknUrdQeGVPMawuLM2g7N0E8Q8/00E9SefZFNQ5wnbbIP6/kaefSuPdhDxAsvrotu2WCYwGMUjUG9T1PXP4vSDnLIjTI7i4AD794Q3AMxvbtcdScsRSU9OMKiDihQVxYooYg5kRXV1cauZk0KOgSqLRKm8uQ9puREDKhSg0GDXE6CHREAIZPhnUw5FDja0ZcD7nr/FhNvOb0UONP/8LiOHUiEXZHHnbM35CR1+9d3b90Uedle+FTA2QYafvbXz6WvfyFRSoOZ6yc/397o1/xkathHYadyytFV7Ni8AsNJrOrezQXmVwr5ePiYcm6aWh2VzLkaiKwI6wbWSgs2gWDAQuO6PVNjJTO1UoRYAnjd9Rve4SRrdjQK3s9aV6c2DywyK/jUDBVA+nDx3PF1o7njLhCBPcC1LqxBJpVYIWmma4vyQLm9JqpGkmkhUaCWsnhbwQlkqs4M+8UnYnUub0xRIc+4CmNlBzW8rPjeWfk7qt+KLZSCsp9Y8dK5UrMJcB7whvG9u2P/OzLGNfiet+QmaRTfaKKUFSzSMDP0mMVXexRzakhUm7/ujrnHGRO37N0vlSo+lYMEPsbk3xsPxw2/D2p57yuDFHdWmsgdhtFVciPXF0PIk2yXAokRtQElqeSc4uhMtXcLjk+VgS/3/7cH6xVlne9tTw064bNMZMQsmlRYqfLAJPjqa02iIqxRc5zeJCGazj280npZfBbSPn+oHDNhdHDkwJwN+LhTYgVEBEWChhQHwrZE4ijipEHhRLop6leoVs3EcqtcPgjmM4X2ezvYgKcCRyhcM87cA89shHZzwXL8+tkGmm/+NQ41C4pfCkulkTaNCmLlytcINrd+3am517F8Sdu/bOle7Kxc7K66v3vibs6YR7dljes2DWKs+VZyDMv1Fbqs9EPoPYrvEDU8/umyrunjgAx6MCvLb4g/cR1EFOdQUrmbVRtz5fORU1we5HRcHn18Cer7K3YVSn+gAaBOsBvhhcjBboRIqd7JaCe1U81mU0tifiaBuiNDyGoj6sATdPXtOhGnDawYraqAxOTu7ZRQ8y8FPa3ouCey9Ojh8QDGDW/RKNMTg1RexXBv+LOa2t9ABcPS53SudQ7hD3P2/hELTF4lMEDHp6+FfIQqMvEDcTCn6ajVPEgQsxLoythZfRTlaB8jQtNZqebjAaEuqH8E90x8btovdCmF+qYgXoC8Z9pX8GNtkPniI5MQYTD1YqbMR5Nqx47cVla9OaJ4EOB9zUSSfG3nLuAaCiuXi8wnAPZHdwxPjvEyfXvjy58bY4zic7V650Lp4TksTqo6ur9+/DMfdKE5ZHiXOCcvZhySbIxmIbi3NFDi48AP6dtZVOHmICYmilfGS+abDv6DZooY3q89vHxPpN8nCcU+lNbMafCrYGz+zcMTzs50lrMzNLi2WUi58ZxnzuMU2N7JEqaqX9nQ6PR4frtVrTDA62MldNFyzXB9HVWn3WyHOfcQhuXcgox8Utlh2E6ywTbh2E28ky9xmbzzG3To/l/+9S/k/AKeo/B4uC+x/ObX96extNx9ABcRFFC/3infouPYRPEeIlhH8KVgBWolYXv0dB5ESB48msbi0FxMVv8MVZzkhBkTDIq0fK1ZfR1XFRsCwoxMnJb8POkKUp31MDuMVMOFtt5GOTpzJJuFsp4fIz5qzPPWYTMZV0SkKOGGtgJbZXJe2azEwkugxEl0uYX/UQ7fPbyB4FoATu7BrnUu1k9XUyLOyFm53PzgGO/S4xW4fFN0SsYjDWRkc82NjGMBinvnP1687rH1JlgtStfXnrxwdn1979EFKPIbw+JQhZ++hG5+G7sXRcvqlDeOeEedR5mlhFqtiZUSNNiEV0HBkzhuiNswL5Sy6fic2NTjfW9oJWW7D0fKCN9emV7wayfgqqBRDl5z4hsGWxTrBIeQInxCuhe/Y0gkzfXLt/ndQz1D0xz+JiodJ8jLgsTXn3k7s0606KUNoQum0x8O7lc503rhKyN3Vi48Sl9UenzbVbu/5D58Jb8oqzkhFBy86G6F7/jO4+RhC+9JrTKbVLCHTeuzMkiRT195rK9Zu3vWM3J0lPKS26byzuncDhAyh2whO4S1G/mcm6V53nHuGZwa/dUt5hAo8rbsNMz1RJzjBX75zrXP+gc/kaQ1A7a3D5WrAXaC/maBhD4hus3rlOek7EdI/vE8GAVARlOhIhqpDonyCng8ejSiV/tCpEPqCqYWlmAXTDXDAciAeH1chPKaMKQaBFRDZzfuK/F9XnHhcYZZVSZRaO4qyllJiZF0J+xrH7orVCI5NI7bugiHF7hql11kAu4fTIyLZC2K8rqREboePJ0rBxDBOdXpAh6nhyshOLMSQLGn4BhrCdO3ZkXTgt6Wtne9S9ZLvQVWuLMgJja9xTznCew8iE8p/w8Y7hX+1MD2pD5zw2GUBoCoezjzwzPKLgZvANaBUAioYLDBmbccjeiEMtHG07veE+LA2/jN1Shl+ekkqQKeTHrC54YpQmPBko//I33cv3QPN+835n5Vb3n2+u33xXud2II0wI+EHaKMFUsX7j0cb7N9Zv3+z88JqgdfICg3Q96MnTOfWNIBXkG75JLH+T+FMFdCn8+GDld/snAxoBJRalVgK+U1bvn9u4en/91YfUObtZDJSpLMeN0INLqEbKLJQbGJRRO2rc3Ka+UwgVYgNAAEUJ7aGe69Ypp5PqYGaUYE/U3NIIxgnMINh45cbajb/7MoV6mmR1hMu1C0b6XwtP/iv/q8EU+LNUqdG8WDcun1j/4iTcyO+ugB1Grif1ka7m1fuf032GlfOVbzpNsDnmJwrHLMaAS5NfvhF/Z+JKJeAmWeBJFwVHYvcf1etT8yQ5JJ/5AS6+lVtiVtZPf9V545pikRxWbuPq3YAVr1tUZ7cU2mYm0s1rA3xyg71tNB8BezVJQn08PpFTxxvMn7jcDS7HPncLqD8JpkNVHgn2cb1XVV8LPqaGw+TE5+INQHAC+EfBwIIUN8fQUqM+dLhcHZqhyUcgJ/En4ArJO6SaN04sPSwdqUdRvllruIpr3uKx40Qe3HKc+rWxDaHIbOhZs60wEZyf2q9C0r7lDbATL8w08ToknbccxnE5NjHMQbgu6ur4qTgPAEwEYXFmvlaeMUyg9JvyUJeqSxA36OoM5Qt1hOaXmuXK4PH5sqA3KilIfmZhlr2Msb/Wc+wojijdI9JRr8W7ImudTejN0txx1+SE6fSwS/ASgqHwYWpHzBNExfkytbQBk/hmhHOzhN7cHgG2OmAlQYyvZ7mRNzfhS0tlTPUbVucoxcqgjGn3dJOzjx2LUmYvdoohGc47VwJZf0BCl8o5yJz75Wtr52+JC4AyskBqSMqhfeaEuBt05r3XxbefiNMuFyegDWOl2LWXSbRrThc54ciZgZcwDX+UIbtoYAeeGCelv1WjKvt3xAi773/S/ce73b+d6F75XM0LJaGhh92PX9348CKoTyWtSxwvhanJ/Dh5UVvAPlYIvwrIuEi36rMBzz8cm8NL5UozT/mkytXGYDBWXTaqo5gvZB4w1pQNHgulZchIA8bk0hz+t6paDsZ27RrfPzVowyGjD58R3sFTRRs8y9EZPAEUw6Enlisucv2jGG0MjeNuLeFSidk4QsSpXjpuYTLZGOEQpU9erdipETdbG8ohUIi6hE8ItMMq+YvgOUGItz9bQv/YhviiAWAAJXAmKs2ASQSMkeWZZa6TowMRBpeH49TH0zlfqx0dDCaaEFsIMdBDs/XaIridAhQz+JWXxdI3S0cj8JyaiQBENxqMJVGqVMhQg4MAWw2cTfTCIyCDaDnHP8smgqv8nyCkGDeIVKIKiYtz4llTkv+57Yfz9AOf8xWEj2m+sjlPlRhXjrA1uHT4KYyWGhEbjB4J3htco/Lb6BdOIgWHw6y6VWf7VQBT1l2eEWo3SzpZahs7caTOwCVibhkENmyTHteXXVHWxpOVlf4kok40l5cXd5Ja1yjL8yaLOns71or9MYcvqWYw2BRa2n9gnAGyje2O89OHX3YIpOafbwIX6RBoyA/89YdEiH9m6iwvKpXPS0bLlY6rONEMhj2TKxWQMoVhC+4n8EtqLRplUKrTMozu4DErb3pYB24E4V8ZuF8Frhp9kFTCE4ULXTHu+MVohphJWGlZkBwH0T9CRvKG+QVC88Qey9A7+YP/UhcPkU6DqyTVD19S2gv/uFY47IL/yo2wFfq1GWbH8nehOVY6dWrbucKSujFhdiPcJvti5CmT4oXZzKaa2B0bqWQ4CfKUBAreM8x65oI/CTadYY639rlzREf58zQW1VcU2K4R677puZMsgTQcGRkaTtilw6g2GxbvY9MlmUycB6Sx9RpsOym3heRtWqqSr4uxPwfieR7YN9XY07H9mvWNXXPJenAw+WJY+I+YDFWkCE8yNMbs5ucLC0Z1sTCwkeAKmxaCDYhm6qmlcrDmypERtqpPQMWWz+N+acF/SekmpLNZwiQflemlZe+MjO7mRHhSFPqomtyKigbwLpSzQlsb8Gt03HylVLU0GarZeLbElJ2MYaqPFxsibcHyl5H3hRtCUBI+eyFMow3UZW8BdKJHP33wftKu+lYmGPFUfOrJPWJgutlMXp/RApz8haFloiZCIslCmFRBXTxSc6QrHkUWcpp7r6abHsq5KCSeDPSZhLCWLXprFd2IhWx7BPfa6NLs4kizRiWpBZ6UQnvLgO9UzER9Hgvyv8erLOlgAAWZ2yJPBjWPiycat7GFrNtqK1VNZ+ilpai+nBc9PC7kDz5NOAXt0NE82xFZSdeVDO2mBp8YleuUklY8FOc4NO85IquU3Tb00gprCC2qqe0fhdShmepkY24VTXDutKYUYQpx1sJg6hQfAfYAyUgLVqPRzMtfe/btGtuDj1WCMw91t9mT2IbLAVRFthfXYlye+fnl7d52kJ05ME6pTqiCZi1PRzcX2Hs4gd1Rs09MjuRtNr9Zem8Up7kxzz5B9sPiOsAFojpTrkRFk0hbhFMQ0jLlmkmi46amXZaWDNgL+/YXnxMT+PuxPXs8RkCDDRFdPVauodLJkLGt79P8V6AD3sYkNBhj4Pw2ihaDknQAqonLpdacD2oV7nJ0nFMfLQkBrKLmp1zCE9hYEhJcNNsY5Mom2JMDctVCLA3IxlVwVhSLAe4PLOvOVCLx99IiV11uQur3pmCNIIVxOZql6sAnhfK/qKl4MpjGRDrosgR/IF4fzbCTZEd+o6i4rO4JXV9SQJYxbaZ/NdcQi79STlTco3j1Tt+4yw7D6L+sDI2UZ9RWAjrf55a1yZiC2Pd9zQB/lRCBRt4rlIFac0Y8GTY8RQ0vyh4IR/LTLJ9c2gMEPbeDsYVywU4LZQg27Gh/0El9cVsw58y3w+W7Q7Tn2EWi49NUoBDkYVzyl2O8NsQZdrFL/DJriDqpbJbDXRq98vKueKKNdkSrRh9cvabB3XKHEz/NamFeJqiJ9yyVtFqwSGrdlqrlps8ZPJ5GnDU0+kIG6UkiDFIMpl0rVwh/YyByGE4fFH8XBnZHyslhlFMfiTsxYHhDJe4Q6RoYA03paDVqkgYsz/ElELrBmvZA9ET+PfAsqgxHW+CZPbFrvEhR5ern5MFnRZ+nJ6l0YWBK8AGjYq0h9dnA+MvRzCTc6qPKIrW43JyvVZ8KWhN7J6fEUR3f3Q7UOEVFExTTUhj4fUlQ5dlnl0cx80YeMoEM0k09EDI8hI1gAQGEL+4OhgLZted+n8PJUs4WMpRd0Hs9tYLxKldno7r0uFXbWIjpQBbMhETOodzUqa3XjqMTa6gyu5PKykwPT4or4xjLkMXNobE5RtBZ8k/Eupx8PPDSOUUxtSUOhVOLoe8RuifOQUZJmeUx9NIcaD2GL1euurOoTqThrXVcOXjOhYEKggxikm8QTLdk/9oF5n7xSkF0V2B4EmO05dzAOSTFjCHJkbq1D+hFizXxCH2qLyOJw9NRsLT+67f/sX77VR6tRxgbEky1GDjk9Sv4Rf+Yqqi/jsU71z3zZueNa+sPv+lceIv8TBBHMKlnQWflljLv4zJvKUxvUZO4pYB919pXdnBRWeegcbgjKkuNeeua9mpslKIM0V+lBQ113kJQUnszJ+FhKbcuSj1sI0lF3gCmcK6E+jDTXfvQ4dno2KHGk5lDk+SXDXWrVVBfxZRPPqUPyHOCoKFIm6/N5dXXoy315/S2Qrtvyx9U5MofuJPxhTLjonON1t+j8FfDMmHba8j1fG5ebglGbxgazzQOMWG6VY0ecF0w9tmwkYSnGI/dM0A+CwO2b6Dje4CsGVYzGuzY8RQne/NFCCK52WKOdG6LhN3QKdgaQyrXFriaiS+HtvBYXqpnABlOXCYyN5uBc/hSnVBtQ/06RzZO5FxH4UuYlH/lIChxqktHojpNEkT+Fxlu1gbLpRaExM7OmOBnMTpc++XwMDtk2x5dfSEliNo0RsIgN+tFRzBjUzRAghHQAS6vKuvt4Ev1PD5yokZjjpSCj2OoMke4pK97SZVUygGZarUNgR/DxzL7JtEWlTPsUtm0jhhVSK/zBkblVmeijFFUCB/lmWa/VVkPzXQHMqxXbCsYCMUYoQFVcN3lP0UAtl4/Uq46DVF9ccxKQE0XX4kLlT4Tf2Bl7VDiLXtQLO0g0Jwp85txhbp/tNTyt6s6MyYBRQZZDk3F3HHKc0zNJHmloTxJfhbgToRFtBxnojOk+1yKqeUJZa3YftZ7YTIznGPSStGUSRhJXwMcqCodnncOD2c9y9KYlkMuBHLEAwnZEf1R5p7k44hjCZFR/QOVq2wgKR7M5gLrhuIdoOg5E3Y854ENz7l44E7TS/UKpoT0XwfBk0FsP+njgb0AD8jF6hEF5boTHaHNIAPMyPQSInH3n6LJPPLWlJio4tmkjaraVBjA6YM0K7UmmtJAMGC8qtW/igbdCFuYS1RNTFkqgc2JSVx1IqS09oaOhXZy1gS0qUi/Jsj0UpqbK8/QIovLjlbH3CwsrU/t++343uJzE3vGJ7Ox2aUISjWrWb9P+VakIIOqBUx5qlvQcQgyJhDmIZvNauUvSIOYxFWxpT22oDUSOfA+5jLEluRRYMGdYU7cdMWiKeqXmVcZ/reMBhxVrZRxAVqjMW8yCEeiWanIqpePgPO3cetY9y3iSiPcGeUREl/Crqp74mE4IoJIPH4zGDuUqrlpKF1AhE0HFww5MnhoK3xjUXe1hsp/ydCk8JXpd3YAzSgwV+Vj5VlAapYZEUzcd/BEKzUxT7jgeyuQGKwupTvtxcSTiHrzFnZPrTaOW8yOGls7gQYahxc2vnX61CmGokaaiLQ59l2humtSj6w6jjcnvE65NftYnwEfGJyME7AC8DUH9dto+XCtVJ+dkMr1rOORgNEw8qJSnfDTLzFKKtnATTGS2iFv4EL6re+J07FvNvRWkgKKECLtO0KMcAF6LwgsC2gYt43Z3JWSxsRfQh/GZLI/YAZGHqpKlMpvf1i7//ramZUgaEHhtnnB2t88i7dssP7GK2uv3KX0CvKj2DVsf9n94Hz3vdP0IYFhdFbeX796zfrc8528yYN/m9y3VxZ2rvdNp+uQlU9C+eDYjmD1zl/A/ZQnxB6Yefkm1wAu/DENBX66pdDmIFyt5fKD/mftoXce/qVz5hw5D3fOXVi/cQNUVlE14xtcVjDZ8M44721nKjunrm28eo0n/8Ibq/fOrt3/bu2Tk2vffdp58K4crrtu/zy5cfrC+s0vuq+e+vHBSuf6+2INf3xwRha37mBDXWHvUWfqk7WkHh1/6EyL6ncgWGgIkQLc0cu3ZABySxA0w3PFOEKE1r2s3M7LjVKzuWySBMHH4Al6MnCZTOLZx/ZOThyceu4ZbbDejlEBMxVxbQSTxql7QbRVEcMCqX6QYIMG4fBA7o4D0UtLgq3hItL1gqCFNJQrX9zEm4lem684/zpCHdLTIug6qkcyjagyF/dqgaeDdguqgkrtSFFwn40S6NxEOUFjikYNlBkE7wpQF4ATNXhDg7uqGPJMHVx0m+VSxbjexFzo/s3Wis+PT7n94g5VZ5mTyODfh2uzy1I9Z3z/wvjY7k1UwNorVYNdCgaoylrjfBFRDcBMC5mUiFijEoN0KCWw1QI2U4DOHmCmFVej2F6NoHykWqtbNzxdrdhJvEGM5GO/waTzAz1Q+YcaQxmND1EkcLis+QwwI7aCotBmVUzIIhnM5ssMIaEYcubmoGhYV7DQU43+tDuGY/GlVpg8cgyjjPWwHSPqDI7UjifQvIXZC2atflo3YqoeplSQFRlAf/hnZurA2HPPTezKmjl6DXkhkGwX6L8tYpeM4OAv72MulqErFgIpf1KcjcRZqzTk74S0XD3iPFX9mfj0Qhi6Fz/GVV49J/i7vbXmc2DzcwCQHmddJEOnNWG5gJm7Hhvv6eGnAJ+Wl7FcFdzeAvleNFm7CGaipWpJwvSFqR1B7ae4i8DDyMprhh4+yEmPiJ27IAjjEAm1oUwvFqJzxgw2PsTSZyjzoIWwjkPw4/+Ac3tdyBOjtGYG6hlecajHpAVoLM2Rcw5+LESRctX9OushfjIsObPdVALp9/NiXSHRwC4aa36KvKnMoffz2Z6oegSTuwJUAnAZvLOy2dSvQabP7+KcyIxyRArlWr4hpMooTPv8QDQn1j2q5/erIAlEn6WnqZ/+e94ccH4fKcGphka1PDdn4zNKyiCkAKBGcUkg3oJ51+cPioMF21E0II8vl1On1+6srqlho2Gom8nT/nFUQEhRgubfy3tM4jG3WI+peTjhgkHAxGj4TLlwzQXFImT5LBbl/V+qH4GwhK1Hj8Nf7q1bJ/alOCMIgqthtgpUajNHIZOHbHtwj3hgjLextCi6mR1UzbsN6ztcCNjAbxS5au4o/8rxxSz5aZPRjzCll/3evH7xgo/12rVci4HK69wePR5jaASQw2z95uxCudlEGZ++/3XwDDGgSwsZX00aRPzXwVPbYyFPXJ1HOR2vaxp6VFAtPxlsc9kDf3W0zeeXmggfKeea/93cZSvX1l24pCVzrwfglcfxTysdgTFgSjMDI8UFyMZDEfX2sUrT3sFvRn6ufUAzHovIog9Gg20eaJOo0mdF/ru997LnxbKzL+L+qA6XJeCYB9XoSK3JPouCmS/PUtgeV8WnNWjUglLQqNSOB/Ni0zbmS0cjrmu2FhGZPIznG/x/THWDrIj9ID2Ht0hN9H2GucQgJiZG2I7MNuOwxbaeXkoJ8ni8XlosQsblyNiALA7BBJDMgXltIKoy8ZRBMuTGvEGEsHDPvdyH9Q9lplQEDTkLM5WauO6zPU5EjODpm2Ji/7Gdntsi/oi7yHVo1ySayMGx54oTe8endqr4AvGNC6//GOCccs0kBqaWeuEzUfp39AD+PLatuH0gDc2TIBNjcIv82AJdNIVwnKhcQJmNgXv2zxl4k4+E2X6hgXSMpbcqjn8KDeu52Z1MhrqT6+GikM359BC8uaE68zbXMp/2ZmBfA7eUXk3+yy1gSBWoVPa/p/Bmy0DhWnEM4UvZdKTFzdSCJ0P/PIaJULRkasrbbu/xnyJ4LMJhyVrelOAL6GThRWdEdKZMc1AMefMKqZz9NGCzGekIDwg6+XtoAySFxmhLfDg1DjAt7UPV8eqxcr1WxRir50XXnz34PLk0gj6gObM4OnzIcHyYC8FnUpzAWVRDjLaoO+2g+NJSrVnKH1kq1WfjH0w2a4ujeV2Y1yoPMOFUNqt8R+3k0KZb54hYETZDsYaVgaaSllAlGcrPchYhyKYhfs4ZP8UR3kKw0LjOW1LQoMwpNux7hq+p0UXKHWydKsStUpOAewG2kJ0vGoKqo5dw0ckVtqUdRttgaiunOfVa+cm0wR3czGU3ctLVTo4EM3rDzMeNG8dLxJvPhdqlVqbCaIemksJcKKsTvX2CW0bn2uhY2wD/X0gUlK+BzSRiz9oWdqetXYTjRQZaNH9t1+e3UV5YrESGy28LZ6E9cCDCP0aFADYnBH5xFctHk9HM6FMDU8QswBaGB9uGB/bW9kbHAbpfCFJHosZoE5LTMJT/1MKi/F1rRjPNF2oLkfVgErFFRkHPOtMc2FVaLB0uQ66HZ0EvImjJpBDUd43tL4o7sfjsxN7dRZ7YgRYvV3uTXsgpnsi0Nywf5D78lnX+l3Qf7xoc8XKpEqSlURlw9jie14FnBWVvTNXcx/vFouybc5+mrLSPUKkUOoStYe4ItbOZXAf+/DbicaV2JF8RNLwiTki9GuRnjKFRziGxkcXmFAuqPNVGDRL0GLvu4IulxtHR4eFf/vL/ow0YgiNm/9uEFaK5PiIBpOKkNIMiB8TTgIiLV0ofzvvxe6VZnjmqp5Anddv2fofAXS9OTbw4fiBxAJMl2GeBcowQV5Ecieg0tC4ksH3VZ2s1bL4la53YK/bJ78b2FHePPzd2cM9UuyFKQfUTVQIL6lV6bEYIDKWZZRxUYwA+1WeCv/NTCQSgahgUInk2Xti377cw9F88gWxHY/5QNRIzHqRHSiA226FqaGVSi2MqzZaiBbHzhawhOG0FiEWcKZrGq8qQh1JCI8e0arE8a8etQLyLJnPV5Yz0nHXYW3Jgg101F4pKxJ4pz7ZzaOOtC+lUx9TDL/THwXanpUtGwYm/N2Id9u87MFWUgsgktcQ8DY0L/HWLor0Mx6zYI4jPDnuBc2kVq/qiqGb/xG7yXUY1T8zvWuJRPpXgu0xhGWqeEyYZ2RzR31wwv1zUM25aJMhCHkOz62MFZeV+RC6dA8GTQd5v7bbrqdRqixBqQCgR28KkvPI+gFWvGkBLUSSvztSjEqWfg7zgYIrLyDZz3k2X1csyPPh0AnK4JbgbMj+L/IlZse354odmsjxcsSdGrVARNufR/adTZiZAGWxmTcl5BBMEakkwnjqQZii0MBL6aIZ3I57ixHPPrRsnXfbuZzruGZnmBzM5WgedICG5LifCuTQLXCroscVmGBTUT9RYLc9kwEtv29MkrM+DM2Ds/a/V1yMDfRohDdXRfAkTcEDDbFOogTIA71ZlVxiwJBwxV2h4Zaplclum1v1wUkEhB+lytGi+YpJhympMOHcz0lmVndJt0wyj3xuvzAhuIFZuFCFQJ6OCurI91lBL6eyahV6htj6kLwoXOtIez5EdhGWQS7U69vnmXkDSbAhzivlw+vx20gCMFaLQYxH/uE8ATxICflnDQBwutYNG1doL8jMc+uG79bdQHX7cQL4KvC6TvOnwiDQqUbSY2ZbtD9jssCDbRweSK7C143+sCZKEmLZzYffK52uX35SPxBUd5JcCJ9zUfKKFCPMpxKEG+WqwcxjCy9KmNGFT+GBt0adq49OPO/e+6Nz+Fty7bpz98cHZ1ft/W7v4OsFGrt4HVPeNEyc6p++Jlls8DCeznNGH3q0iGCPAUV94T+phGKWafLxuXO2+eyuhLU99648+XL33EfUWsl1hcgHOMMlAaZdaW3LBFnJ5425m254WmP4ah9AGKsaLRs2vTbTjHzHlTkNd7z/a6xfBc5HY5GAiORyV6kK2PHhgT3CsXBIfC6kraNaCowAbUW5CXAaARkBRNnkg1SFDSM+gA0tnOeCyRD8Nhd5KA6vx3/tEfid3t7S8rwaqO8W2jbRk59uU9EpirIC6Dv+OscBGgNrcFpqtsCX+bYeHqlu0iyd0tBw1RhSsE2eHZVx2cDYCuQ5y0B4rg4E9oWQakCtpAMkLFBDcMYGFOKLdd7+TB4cyK1horAwbrgI6/8PrIzASLC3C1T96aPbJ/6PSbtOvprjaK/Rn9PJiWUzN8L8kKTWtwYAZbXAi+DP882K236GtPbjXufWWwiInKtD5y7nOvXc6n1lZ2mfLpSNVtDuNmPG1LEETCVi/+Ub3vev2dKC+2ucjzhWsP/qg+60gHmfIvbVz48z6306t37hFuSoAJP+da6t37q9fuNw5926wLeg8ONH58k0q5qQo0fZoPCCSwaIUlll16Ivo7m2FPEnQHomBeriM6pSGrELMLyF6yxcZx60WU3AEyvuXTsKWgiRulmTC0fosk4j2QbiBfZGJAVlT7Li2th3cO7l/fJd6Mrlv12+Lk1MHxsdezPpi6lsQu78MGYiABcEfzEUbQQW8Drv3TsZclBX3UprL6cCDjG39A59YxDV1jILwXPyPoyRL4BCs+pa1M+vxTJTKkS0wmV2jKV7/8m/dv16kzGomiHAA2QoAEh5MAtBsoLaQ48y88cG3aye/7nz6oVwt3AFbpD4eLqvOD6fobG/JtgHpExMfrD/668aJSxuXT6zeP9+58Wl35ba44Shlgt7wcVz5qT2TPVLM4THvnS4wwY5ppg8UDOesBwrcTzy8uTCednUPg4QdRuG5mVAcaNL5etzgZT4lIiZidmlgSbhhdPjVN191bv197f5X3ZX3nOR5dNK773+flN0KPjGyArlpbigZsnGnq0gWSQpivSLWpXPrEnRr5XWxF2irrd3/cu3+de7QP0+uXXszmQD9T0g5wGGnC3fzyz9ZWBvoV0TtJdUY00qclppwPHHo86iKKMmGy5l+eByj268ABMJPNo5UHxJz2r3+t86dO8hF6TaJYSJmvHvplc7Jy6HhE+gTuvkTxfOGseMgDoAJhgLaJIkyAhyKQWTaQ60tQ8wh+/SR2TaTqqWGuk9AF7wZxHtHK550+DW8g3nHs6xy+nT3k9t0R8C1fREAZu5cp5mi/gAiBE0MIN6fvNy9/qmM3LBuwMeRx72aip5ZNRQDx8tkpr5KkzdSPJRRNcDM/eCk+tN16VFkkQKJiOmSwhbeWeoWI3rDyCdwQKa3mP0CaBNBDCghCEm0BkO0Lei+/3nn0ftmlpM4pfX3Q+b62UQP6C68eTt+C8agV4TUKipdu/+WoM1GClSNusvMFOZLYb4qbsUWt0g0Q0qwuVB0laTLYGJ/0OKPBmURIf+QXdvzImbW9p9TpUOEMyergZzg6NeG5/byrc7Ze+L0EqT4lnZLtmJi5fJwYlcLr/yNv258eIrmB0bSefts5/7364+uUGZAY3V3pC+r6L3KLUH8M6zLqc+hXuSIPvpO8C26DgwvlNRcKRCJwedcwJQAnaQ0FYQo+V9EWwJGXvp3GbkidfyC9FnCOmQVyAjJerKbwAdRhleNEsLJ6WUqt6SE8hRfnJBQXnuNJJja6eucHqNLO1DhpQeJhVVn0wrzHMZKW82bPi5Wb60eSZjOanTcunYB/aIxGJF/EMk4B8b3jv9+fHdxj+DOx54fF7P2BOU9TEwR5Qfi3FxGHUH3QWsAdlzx0+RYcoGlc2YzoiGwjfQlRnqw/kmcNARJYt86p1bo1gp4/xjnoqn3MIO/UIM9U+LSyihR09r5ihxM7h3fs6c4tnv3gfHJyfHJ4nMT43t2YwpULBjLaeYYy0Jy6IWi096qCgPGx9pkQ6wefn24VqtkeBfBbtg7NjXxO80ZUjU62+X43rFn94i9ApSxd3ct7s/srKeagk7EFdL9H9Uboa9yXiQKkZdFp0POQIYIdvxQfz1t1GkAZif2czqmn9d3AULUhy140QYRDHNZyD4VYviL0ge2JJhrLsYbWafbliihFJ44MqCDK7lrAN1JGe+E7HAExlGCq08NirA4AmSKkVjI/YcE1OMWAZvYRNNoHY2WRxLTpJA8zFdwmlXCYOREDRrty55hE/VObsZ220BL5X/l4ZfTtliaOSrIaSMjpqxSwpu0COnFrHmThdCZFNWZI4FSazYaGLe1iABq2ylRiUSsN/5umxTGbMm4Z7kZMxexkD1HQ53+jEX2UUN2l/BboxqIi+bTMFJxzbgMADxdwuuVH2JSAG6Z10NlnTMzPvGH2ULSSBTSMt6B8extBuoJwRLKF3JRY6YFaeFiID/1gSIesS/wVigtNgG0DUVanEpTcHYK8EZAEUYllcvLWx+QUwGnexZ32Ewpb1xG8GirNDM42wp0smXwolqqqxvEfIY76eVndhZ37sD4voVZ8QcAkkMhflZfEH9Q5N5ipdSEiIrBhZKooyqqFDfHcfAMtvSfVgtsvbeTdsmBZ+VrXioxK0N0l87yv7RaDlaK5wJ852b37ElOp8U1oHLs4OGlanNpaHd0uFyqQibR/QeD1Tv3AhwqphbEAcZS2JhjMC9q3mjOVb1nbO/uib3PF5OvbKpVhc3yb+PytatIvYS5O7zlOR2YTL2ocxpodbDqtNl2yzADiZtDGVlIbEBAZaclk7u1nYK0A3QI+Hiwb0BJjlnXpOshPATvQ0i/pBV0xu01Eky36K4TJbnNfKNBukBKNDUC3kal2dpxkJkbMqlbhMGpMpIg0R2aRmolnMDMiVuNKosYblOVYkC2beSsoMRx0M2tFLpRPDD+b+O7pooHDqLTfvji2NSuF3IMjl+QTtL2HCKkig/Q2OiDLiNYm1oDe+l0WnJNjSK44hyv1WcxN+SkriVYv/hQCG7KmEEwK0m9kPLr5WuGKNU985fOgxNCIgv+6/W3g20giZ44033zP9e/OEkiLiTqRWgTSg619u0H6999t3rnze57DHYijhUDb1z8unPz9bVPTrJa8cuTotjqo4871z9whWhPH92NaENH03UE1E9ek2WEIJvOOJOmYXPTVY/qZuF6DTjGdL8YnZxgE74xCBp0vJqg3GLnOik3MJXYhJNdIk+T7HznYgpC5wRRmy0fAdhswhDHDj+BnhJxB6ceDo6h5dmIVaU5O/nVx7HG+nB8Ssmf5kk2FcMY74HF7slClecdG2YTPOIGEvxEhge3P51NS6785jdrX79JRxxsta8+JC0v6fwQlqfz9llAFzZNRqTzWr1znt0XHC2aTo9r4KpvIveRgwCfPh8qP8/SoiJLJi67xdTLy/GF8T37QZmL7EIRb9li0cZxsFx5e/h8q9OU7vMNcVvA+AEKiklhudtpISBpsR9Bv6DxGq9Zwcj3DhfRkURy8nQwkfkkFk+kK9kv7p7RJ+Me1PZqtAO5fnmglwMygAq/zm/mcwzy7D/UgJ9sH/5fiz5wA9Osmd1MbELfITGWw3u/juk4WS6n6rlaHA2VOg3qZni6Z9Jo51tX/pB9sOGaUQdKe05Iw+jGU0GMBMtc4mO3+yOIoB+WzhKgt0epgNTLZEsgnkQw/52LNztvXLNNmsD5Q7ZYrwjlVdWYGjzUfdlSQAwemUG8i8Db6ZaiWbpY2GSOgXbqE9JXjJK7EJg2fviLYNTWH33YuXCLBi3dAchcAfHOKN6wm8Z0y2oUtfqPTnWufr2lXRCcbVahmIs3ZkntF0t9XVoUBaPSAr4kaF/LM49912UjKPnFnT7gddzTgzwrPH4ePS1efA3CncYXIAyfb74LF1d/+MiZle7lM4H0l4A5w0mytwFLdsoNZllcLuHa1RvrNz6jzUU7zrwQfnxwZf3m5+zISJvu9Fed238XLdCOEzcv56TwhhO4m0trhSyVkI3CKAhGkRIUiOXhczaocpQ4+QGdraax5syCqmqdGSeW+11VKqbJ6AFZnEpLzZoxk4zY7/aNGKeUXknOKimrjS8BX+/0lNbMzaKeGJaXOD9kGbPBn+2HyECKhyATO301vKg0lInVgtSiIR/cVxpD1URW8cLIGzv5IUDgsL2dnb7FAhlcQGjonTiTusG04IesI9vALrTrs2lUGD8fyJYOYcoLtr5Ob1y60L18zyJBveNb2LmCrEwIcMcY4zAipMDUFdyNYtoERaVi8B5UCTOLQ3GhIO52bVjFNbkBw5t46OkVSq/iVQ5V06MMuRjV67ZrBindUK4fCYgSSs0EJxc2pXpIbTUjyEODAAuKS/VKozQXZZ7a7kNs1ifazNfpHKgRPBr6OjK5GE+SA4DPA/6W/FU9KQ9idUiI9l+a6FySpoFVMAOXqhnFwQYlhy/tw2JJJUx1v1dZlU2zTco6zNZN5Kq4hOLvi6XBM7tEffDljFPZRx0VnWmtdzkbybKYmY42Lp+g9EdwxIZUTpl27EpLTWtjAaBiqhrlOdi9drXz4MLq3Suipc7la6QeIseO3u0mqZ4crY4QFpccTlHq/+kolase8FIPO4AJzYPJyReCtfsrgtJAPnNUZXlIEs3r2o2raxdf1732kbgUjaqVfCexkZgDIajbiIWj+SRO5dy7UMOl11bvvNG9c4eCI7Qe7cJX4qPu9c+Ynf3gh7XP7kEMhfjwwherd06IykxniEuvKbeKoHPzgXhlL4300bj+GbNP2PnVe+fJd4a0e523z7JTkRHBAY3eOSe2A2gD3/mHmHT+BD0UYxsPZ89BtJJ+aukuXTHxJDF3T4pTpx10iam7gApzIyOB4dyFxhj9Qrt1ASUVAmk0i4/xGJI/E1tHaDyiFKhiLl/rrJzunvsUmU329HQuHO2OQ5DHZmYudqqG62ELpM4xIJYRWFndpKGZi91FzNIeM9wAdAWZ1zAFSUrl1lW878x8rTwTZUJW/xK7/Zdzqw8vi0mZzpjGK6q+c/d7mqAwm+vHqOqHswFSAXWS0GbSQToMP6lyKf3Klbz7/fqNH1bv3BNkQlC1n6H3jWYN1Y+0e2BGLrzX/X7Frr8Q07by7CcGk3n0hvorVNbxYsQ/TZLKHdw1SXTjJ9ZyYwbnEtoQEKJgiES0RDYFUDUbHcXl9aWdSbgt0uqi1UwIhU5XNTgZWJMve4d2eS9t16064e72zYxX0sS9Y9YiZMy1+xcgCO3OV/SE0skBpX/0V5AxH1yC+w5iUn7ydHgUToQvIg3Ux1PVR8OJ86KIqpgLdj1/+yzLyI8+Xnv3Q7xd3ux+c5VP58XznQs3V+9/Tv7oJFzb8/i47qtefl55kBqkDmnn2e7KRfTzn4EIr0Q+X3YmlrUhF4zve84HhcfH2lKfOcyQY7hPUVB5XOGmxg+8yGL+7NLC4VA5SUixfDmKu25K9uleAN8ExAR23/8eojQv3CRXWrr1mTt5+yyi06+fvy2InUKsty0MYrokejsog4JfB5mncsGvUlk6YjOC/QQw9tTgr1CJ89F33fdurZ1ZEYyo1QTp3+KptRNDpMjH4wh4HrEzKMnixfJiLGAZzYI0ZRxrCTMpBE50TyzSs4xdhP0OrYiYXkotcUSUSx/td8FudS6eVboq0GziWVk7f0uUXHvj++6Jk933Tq/e/x70foIBkQwhsoK+8DGd90incokhhPhTiEhhH9R6zWY9ozLuYQaWJ4MQJe4wdr3RdzBlMlWLHY1KcdUxyR7dEcxplMGrUEvBhzMKOOIQA6E2qrilwIz9NP53fwC759ynpC4kEgRzg+5dsRwyMlri9Ln1228BgcV553BC9W38qo5HD9NaBZS2JmB/FTeBBo7JDJFQq0NhxDQ4JyZa7jhOsIU6EvRuogdhfKrj3Dh4FNDnM0uCfSGtCWXUioUMY6UFXw+iBZh6tBJbT/Ti4e/eR4AmyzwCnVOC9rynoqE2XrmxduPvMVlDNns8Olyv1VARLR8hSib4mNhtI1bsQrmJKaqPQZ6DuXptATI+GMnsQZPYaEq6K2TEGvjJNMVASxUXDv8XgGJeqUTVI1FwXNwwiBorqji8DACzbNarUURW8MzwoI24CzWDwbtG0dp1gkx3hgVmTwxNzlC4oTvqZJx+8TIetZfoEt0jls/ZP9w6ucTqcQx43Ch7rIlTsSqFVce+TfsUbwLUCUW8nRXkjMWBZdwpZmKkV0NvYTVOH38oNlwm1kPrROinukpjhFnPBPdzRdD54CDBjz/v3rvoE/fn8MszP5jphVX4LtqQ7IhkbzSGAhpIv/pwLlgjTEYriFy8+JYyV5F9yrBAScOL5ktkIIuhxSOKMmpTmBSRVvqV+4OQqauPF3vcK6A3Yelw2BRvSQG+dKODTIUhcvYsBRAPPIbuim6kL1Eq65zPlxqAi7BDDBY8cOD+hoDoURfEGO9/eGvATVkJGReP7cQJw1x/LaxnR0HGVsc+RBNEUls72xaJVl1Ez2/RTn9RbRwRffM2CZ6dC1+5lrzrFxWDREmqxHVN8hMFL4GcL7bh6XtqagHlOAD57OMTXgug1VX0EN5kd4l5hRhhe03966nNLEyDfs4bQHLA1eg4M8By67faOTpUOdlwLk6sEucmgZVwcTowGx5k05sRvzPwCDG6feoFnD/mj2CFhEDYPX9t/dxFVjDdep1CwAKVigyEj9/tGZ+cDMQB3TMx9YfgyIH9u0zvQpVZt7V1K3sOMkczggmFMzaXwyHI8vYAkOLECCXDp5whtSsyhE/cH+ICUQESFC+s2GXuh2xkVP6h5SVZU0wjZMjSpFnCmaGT4YvSNtDX6PqXXZIQBSoglZuMBz3vHn9u/MABGd5iuWvEBAGJYM2CQCy82UmDhC32RPMh3T7Ho793t3t1ZfXOdd4JnuBj0Bu8fo5i5YN8niNboEPxfaEQL3ohYBjlsMIRFdWpAYyNOM9Y/VZ0g8zYyhMgMZUxWg7g3KsU76E2IebSkFtC8A52GLpsS6sB+AhzjdYikL+k1RC7bMjW4uAFRNbE4Tt7qnPxaxkZ/d8nTjJ8hrsEdlpaua8Qr6b7/idkXgh19IDbn1QlBeE0wDJMpzabMEWeVFzYO0um4Ta8anWYhlP/2Hj/urhTVu+zxWTty/sbH37GsCJ6Xrge214f3xlHo2XYGPnAeeJtf/3Tr6k1mka4/Yzw486FN4AbRCNS58Ir3Xdvrd69Ii7D7p1T4pO+fV1IyaIibqERDLr98cEVMk0prePalevdS6+AjPzor6G/x32QKi+5SgxmQ3gJm1xJ7WZUpBTUmGHKobe831wvGyuUm4w46zdf76x8TQoUdCGiKaaI6P868YX4/6AHrCw15g2zLvf32GKjKAOpsbtCcAetkvncl6KUQpjZ9oYtaYuQ+S2A7diNW268pPiTgkrWDouKiTF9hdnk85K36Dw6tXH1PnE0YlnJfMZwJJde635y1wUlIRtSYPgjGeTJ8ldC9yEidL60mJZPE7I4bi0DPZyXqCtZz2QZraj2LW9oQXG5lpE0kLi4ZKYWUKHuFABoh1RKCmiFpbjzgm0ETzE9ez19qFI80wf69J1K95va2S8K246sG4TqdKjAjQx4ilDkLnVUcR86yze49atsEBxgv+/glBlWbkioKjn5Yzq16ApiHi1JMa98BOVJBrqhfSjeu9t5cAEzyOL42h7KYWphIPS/Uj4y35R8GeqiyDI96tyKLu0jzzUf1aOrlX3bQBSAdIKV8p/0cFSOcwDJEYtu8R5pDIUJG+q5zCHo02x8xPHJgZh5SCgqozD4drRptkwmAWnehrclpDhmkCUC6SDxix1AwW7+zDDL2hfPdq9/TpERpjMNnLr4yrhBItOZZ4bJlyzMFnLa2+pPqEOgtEGjmz00CmXU5b+S9xuKKNUGLHoCQoGNVgV3MHojeKDbfnywIojQ2vUf1t75u1Kykm/Mjw/OJNw1Zod9DBtpoY9VogYFvSvuVZY15udYGe1C5P9uMhF6Z1tFbInF/25O7CvuswFa5t2HmrHrnj1DPhMkdK5/+Vpn5UPihZjbYj9eb6L6hOoZZqraYAfGcChMgUBK8BXxQyzxWdE2BH4Ftg7XvECvhlqqKwpiCYAYRb8Q94njaeRCVsoL5WbxyGFL0SAfxqmA0joAUhJWy+Jr4g6BZwzZpEx36kX8QPTphGq5MZ36++q9r8mHSfDFGx9eFPv9+fKz4hoehphgcGf68OLGpx+LvQ46LNsrPhzuA3ndN4OOk/z/tKtpPO5JJTzoP25KWQm8+zidGPVIdc6E0mbBhbhcqoMGwjRmW4SfSRyKQ1wTB02Nxnqq5HrM/Kxg3zx15ziXFZGXpJp+ymzUIUHIQqIonyGUEqvNJMHcj2InOFL3ja0F6PU/YB69mQrQNOG8UVXb+K/2IN38kgAUxKnItY7JvAlRUgOyFENfyrJ/hoeS9gfeJPOvDdlIww51BZ1kY171kf/lJF/ov68gpCJIwDwTKY9DBK/F/zocii/dlTEzuO/sMux7GsuuxqApGPEWHI4gHZsMTWZ1akCDhPSVYLJEk4zt5wMISlW2w/0CZ0VQ6RLZHyECl02Ts+W5uQhYY2mkHJSDSlxjSAq9XCSwQhv/SnNwJpiWo/NI9bCzDsao9SuH7l8QxDfqOUMx3UbKldw7Ms5OJRAvH0d7UjkFbKNZP596gKLc1Ai+xA3mXsXzpKJz2apl0lLQo4DeLLHNwmb2MtUn0VF0+ree0YNb6a+e5ZSvmYXpaOC7gZtgQ4tJM5UlYwIYQyeOBucF+lSn2ANsr9VYJFoEJq40uOSjRiyOcE8Yd8QVBJ23Hq7e/2z91qvdd7/rAXWnG9L+9muXXiOnFbB3OO0TSGHwe3HhAuAy+EideROR7t9cv/lu9+YFcBpEXsjyl0rnhk1+F/QayAQDLiKKT6bg1Ll4HsSqldugMTx/hboFw0eXdnI/V5ARYMQ7fQ5KOm7p5NpZXc7gLkZ4RtqEHEjFq4z2KL96OT6PF95aO38LoCTJZezSa933vzTHBf71qIw0bUxi+tZPfyWeKzxeUJ9KwcAUCWLoMehfIIHqQPOrbS3yVHIvmR1Cq5SBBgPZLFNBYFx9lR8OQdSidSY5G6YGOXlsR5mu2jwGQcZngPuYry3qDrfM4CKpgGtLxQOG+hMylQ73RzisePC/wqDSwAIIiMlTMWLJVMgakuZHF0d0q538w5+pwwIcoko8ThXe5BuEuQj2PvoOCBBQn/BpZ54Jka2Kuw/I11b6EspjioGJvfsPTiVmvdo2rKMUFivlJtTU8LnizpWjCu6QxnwlepkKZ6B01udWQ6WnR7ajFX46zI/prpB7HaYkwAXDeacP/M43gnVDDSpWSf8MYhrbjFEJYp8UBhLQ0qAKRKujLTKSeN87MwigJlu55W0jBWve1AZamjtu7R1S21pYU1Aka+8pc83wvQZaCQWvG83+tDXrc708a8V9QT2TREmhInkqEqqFM99tK6TPsDnOfB75V3TmFgQTsdMTp5lImLj02SGZB5qqlD1wcC9cz3Ywv1alCmLTWF5Av/5sT3NvS33XDrof3Fz75ovOhdvka2zhmqCtofPw7c7f/0om3865O+sPH2q6zIwR5m4f9XnAH9y/G0awZ9+u3+oYfhiQsouQYqMKYPSc0dtAdDXqz/VwsKekhkBdHIRq7gL/Gjs4ta9oPspayZkFa451xNJXGkxcEk+pM6K6vvves6kZOtVHfmT3kh9mrTS62MmtNGax0WTXDb1ZuUKIhjFcyv+3uW/vbuq69v3fn2Jn3+RaMpKQjaHF46g9BkzglmAGNn3ZioZsbdtq9IoePKLoDpKWVwKBtiFQQprQ0iSnaQxN0/AOY9yPcmvJ9l/9CnfNOddz77W3hEl77ukJtvfe673WXPP5m1Qc/PLMFLBx/4VFWWPyBeSNg2wkGAmTWBntfwGzl6yVONACYu0BOkilwI9IC76xUyr9RhsZgFDIWl5jPCxmx8YRv+m0+alLZw2iRCMxyAvCYXiVGCcsExn8mBMWJiL/IOPsCBejUM8gTjiasCCpASMDTPpyydKD78ayhGipwNS5hIWIbUAutL872twjq7GSb1CuDLHWcqn9pmAECbIikfJKlFsETlnWTzV5FSF0zifJYRDWCC+i1mdcg1cSSKS2Lqm9GyorJYwT4kdE0YeDK2/4F/Cm+wmkKuyGi0wFM8zG5xNh4Tatemo8FGbbgbPWqiCt5gCTQSMZGqWOo9ZTFWWU2yBunVQBc6yIj1NAIt1AHf0bW1LfkglPkWehK0aXR/9H7E/8ys8r+r6rl/GrCHndRNyxBzth7pclMnJM2DaVpGzmPu+3C2APN5M8BpVtBdHIQCGxozu1bcKahoS5PiBUfKTrhIHj2GpK3RSBwPoveWyDL7PuoLZYrcMBlNcuKuy8SivJ+LJ6c7HVdE23HPjeBrSJhNbD3DL0TYQQFQZ4V/dScAGU803MaDWXT74xmfx5lv9MJ3fnktl2OjG6Eyy4rLG4NYgRew1DOjB9dHbvsVk+KvZ94Gsd8H+YTbeYYK9ynHG2cuLbr0wennwZILPcF/8T8oPJOR4KyaEoumFwXZxHVm+0LSAf+7eB6GKIj74oFljZIKvI+cOEWuugAGewiz6vFNUmcvn1crPueRrUvb5P+ISFbRSrDUf6s3OejrsHxURd+szEow04YZYb9GPsfXK/e+cBIASt3lh7cIECHSl+S1tpcLhCvtYWNdqwhEyIbhorYWYuAxMw8scy+eI/Tr/FXft+c1FPfdL96JweqikRxpaLzdxCqbqQa6zkY5A8wwQzZdf4Sqm4kGJvR9lg4UunDQwMftqZT0vq4OYbi8UiSpD4LrXinSwUl72GQp8tePBljjW50loQSiBGCmvVSsMzcSKKDbz4KovqgwR69qJNRTwi1QniyaKNw4Wt4Qa/EPSCfwV5CwESOcI96uVi80BrwaHMeSqO4lc3QHX3yWMMnvykd/W85hUFogRyQ2bb/LmZV04bHn8Pat16fKtd6p490119APnwbmtBVMahEODc4JQDw08t7BqnBYm53HjNu2IwrPGEPEbaDW4L0QUNC2yBlD8o9hlnl7J8fvZHEW7qC4vgM5h2/gMZaT6suPMfGWc0PTbujNAPYMP11y/416VRfMMj1GrjCEQUWMm7g4xKHwzghV19ComZzn9Aa+RLEGYqG3nj7LgslvINMLMfw0NyVCJKgZpY/HWAkfmSV5eJnuG649Gude/1lkcOlUuQW/H1hLNUA3G2wI5RubGccFYY7UNmmN3xrXopBOCazu2Sx65P37GVZAIbYrvqKG+Si5DHjh6SjWTa7uQibBhEIa+x3UVej9uPVwopqnYbaEyBM4I0k8nJZTgx7GMic8kfH5kR+kljT6PAvtAqlgo5sKJ59VhwxuLxFLyL8Z4qNmosjRbJulcrnfJHcNO641lmb/GiiI2JrcV/AGiXfhhgaezGfjRBLKZg9uECHh/bjbFUxrP0Dp6DdzHFZ83/N+3CnyaPsuEdAneN5FEI86gQXbOmOg7fo2f+AugVqPJGLJo/9m683bv2zca3EEq2sfp089qq8KBAlOfPL3WvvAcujndCY5UsSh/eGve2YRflX98WeaPOw3Rh+D3OQeefjy/YKhaEhm0nTmY4Qij/C5zHUoulIpAtXAD8nu2taIx5ojHo7+wYnew9vGLNzAhRW5qZBtMp9k5/FkKgSrjf+L3m/MDxbZ0BiAgYNshfG9OZbnyDCZduf9a9e5mtS/f8NyFUvlBdbJXpGtJsELIvocT7WKUIy/CMpHvt4Vm6BmV3e1fv9i6t2qaFkxUrDyB6LbM5hTBugjhTB+lcwIXGOOhc7gCCt+f2TO790dThfbkfj+ZyTHjhtkKvVGL8g4duTl4dvEZPwdRAFBPVCXJjs4h+3FQvzRXegvgVfm9cjWK1Y8SfsyZSaAFuAFmKLbhW9l8lSpC9GfL5cMDuwSbwEtrhcI0SqnXAa9kNjBX+y0VfTkEGBkAIMCVwyFZC4rr8RrGWepn9sx+YbmCvqgu/yOwBnvngdCzASVA/R7N+poGcPxar5Rp6n/hkD+Xgrb4gmjveh+baMUIEMIefJ0k4bwAv6/Xd5H7W6u8X1z9/t/vw8gC8CSyecIxiJ98/ALaWGks9tnOX/FjnlwM89QsZvgXS2S31O4rpED7a3EJAJ46yM0MOG9bNDKAX46yx32yg3vzOPzo1c+zQrJGxB7mmCagEvACgCvaXR4vhonbDK+TycNeDWIOw6fAPu7U7MlcA+UhY2Y8QDtfKsAz1EwsFdRkazIXPnCmaHojvZB/FfYDvQ8HvYVqtjKckKwGJFxkCm+wKlz8vHjSYk4mbtsS9r3rX78gL7+ZpAl2xRhjKPc3rkYUuUCGqMYKD1TZTY5FxYJoXuEoBNzHkC6CCocjXAZ7ULeVbFbYd6m5C62C+yYgoqOPrC8OxH5bjrx6dPjaLxvHDk0dmDkzPgoNubG4y+fN88o10cve27Znstrj74jDdDZV8rbFSJcFNJD/ndQby5+k9RSWLKAx/QPHWgiq7AMdGBallMvYv/LOhj5fylCRkO4y0poTQxmmDPvuu0NSL+TGXgVeSA1cBaerEP9Daj+4Y7CRyFwNwDGBLCQeWbzpQXJLvGHsmlT8u97FjzyCAw1RjuADPmSQzGvsgIi+gBKxVX8sEb3unD+8/6Ldpuc0StImRIy7qKvOl5Eq1+hqUnJ7+EebvQ4+gpFAOw+dcmX3wMKv6x5OHsO6OmgkB8svjQU0dumlPGPKb1frZ5gwLgzTz+WyHmtNVx3e0WPfMFQXtMzmqyuUUlro5+AX7i7+gZfdf1M0hv75SszxA45qVz8g8R+ncgh2VOvWA3pyRETLFGumB4ftBU6WEeif2SymM+YGzAZ8RTEEnu0UZ5jWzm0K/hBzzIuyRvxF/sbtOz7/H1xa7VKsC8VUaUWW0R3zJhPQLCjniQcQnzVPIoo3lmljIkom6WPg0oWl9t4t2uQq64bPqoMeX6YkU2sBYWO2WhB/6Ny7ujxRXGChew3Ym4irJKEYkDTC5JzCLgyk/hbYfHyDHZqteJ4HM1kELF1MvVuuDpiIIyMmSB9YZ4x95pywJnrEVnXXlPZ0T+zcb5e0qzLGBQkHDLFoB0OoJNjSOQQIwYLKsOAlZCJiGN7QI+ot4VGc0oyr/NWjOe55DQyhKEPbr36sGMC5+pcyY3G0v5KhpByXEiyZEqUJCSO+tP3RvX9LdaMh1xmlDrZ2gjSH64AfNMPBxoAbfEEPrkASECtCUR1MNVbWNbhjUgFdGBczIFzgwqZncwVem903xxkEoB5mq0cxB3GgoercFdBfmK8qQPbhReSztwzS0ZhakqMkwXEOrSzge5IQsK1sJnKCo86PcuAPFggdJq3wwQkFO8SP+QlZC4adywFdrfAmc2vDGobzG40R/rKJVhfe9OYf2LcFLaCEvWjG6akQISv+rRsOxUWZS8l+Ae0a8TqoqXDFPXOLee2Bq74+OTDNm1nImg9+ANju/6PnCikwFouyI+DhQjSEg8wtnwoaGEUIn5Os+LSjx2WB6SdubQ9EoJmi3LVemfn4GwQTFsCXw9YwOaApDlInrgC8kUelxShMO/ZXjX+je7w0l4WXkiJRvNYZuuUEAlGDINLXNc3BTuxCG72tZA00ygTgYN84by3YieqacJdkxr2H25ln2S7Wer5/aJ/ZPTOS7pzz3kMwYMoO5yPBlmKSIKsGmKDcRcGtKODIyvSKHZocwpQT2bKAYFSnrjHOxLfwmoYKypbjlrOv5JcTnCqPgeXpt9IRNCO+trMF/UZkJuezKK8zUDbAbZSaQLAqJRotzM4MVdNC/KG3YwIvNPSqpLrHYyj0EllxSGI2/wuMm1k+RSaCCykcz1VgJyR1C5WUCap/XFyje0RkU5AXxaaiv55CfTLFuWZVuVhVdEKjNp9wSSkrh44ZLE51CigzeoWyDvxE/Opd88YJFS2idTk6Pwbpw7Ige/GdnnALlpbpIbkoMSI4q7xuzjC1U+1R6pgVWQb2JWgeJO1B4Jvg32p5Mwk/omkKrYjMnkSOkAQCkKtWusebUxZhfZedLb4O3vv1g+LkCIcXJ9iycC37OQVTMBXgGPPkQLYX6NejEVi0VBgZls7pzgYAAk01+zZoamKtIO8+NkC9bAEs6zw8dqkaKZEVCS4XF8st90/eYfFfHzYxMJNMtAcBx57HzZ3t/f4sC4wSYtn92OJYrgYpo5gBbegdxIQVn9H84syuejocjc5/VqYcN+AHBwQ7NtoMSZMruMc5JvSDyejqTZPIUHjKT8CO4BOpvMu5ATnmDNRMQnK03SBRBDjPuda+8R1mCOagbGmN0j0Or5O8jQmopJfWZsOI668f2hfBzG5JzIuh3QcmKyVPg/Qfdy9fXHp7l2OAa4F1wCKGKOY1IPotmTgmEltQq4APHqEUeMCCqtWdSpqPq3AxtxryKUIqDE9IwsrbpDjQ9aC4PoYwLVBCewuO/nWOIuKp0IIfB7pktpgxB1aiZ1mMQv+Jnv1mi9mkISxd6N0UcWZ8TW4jGO+qijiZ+VuuHDE2OSYthQtA7tHoIm6EKKERbyEmRcRNkwfhEX5NNtV5cLlYwPMWYTZsbvo2W8eIRyku7P7yp0BTVCJUmq6qRC0GdC59cX3/6rX8fTaisyoICNAg3Eb3YIvxctaPZrGnhNV4mnBlmi644FUkgpNtD9Oi1CQuSK8PepB75XSQsfgVbmOQB5nXL1GgQb8ZBCPhzkBsrwdsaUf6ubwzf9AY0jwOzUNwF9SJEbDC2CS0pMicU5qt6n3istacfdb+8zk0tCLUhPUN5kkVM1RPmEfv8nQFwjntfUZIa2Q0JQyISQu5GcLgxJ9o/97l78sxj79sSyB7YDOMEGVfIwRxvfr52/xEf25ijN+lvjDRiBFtkensFtWB8v6to8C1AiYZd/HrIuc0fzerBZprk6VNrrsCgPkgOjewjFpsJuqQSo5Bjb4jb9Z95xt5/B4oVTUc1kFoF7KKG/oR1I9FXDRnnuSii2B8u0VIgFO0Ycn+TkU98z914e/3xb2UaLXaY9D23efqCM7qT77vug2+497rP3y1qgfpoaNXGlL8F0rgqhz0NloZHUZGFW1RPQc0iuJmvsKHsmsNXeI/Tb+zO5tAFprMOPgx464Qw6gNlFBxRJUP019hmTGxV0n/jM/47ZYYEjqPEmIh8XUaj56z5hSPCBO3phc+cJ8Br3auRpxgmxQbuCdg3Zy9trH67/mSVCaiYOO+RIEhDGpIDOJ+6rjt3jF252aF9njQkZXjEHvejpNE7sTaNrxMf+kkeSE/Fa56o1l9LViuIC0D4p0OTS0w6CXk3NDdDTWeHZk/VvAw7mqCFGpo66S0izlwGPdBBZaEFI/L2k0JTzxNwiu4MtX2z3BlioxqSoBfhw5xhtK7ARur0G+/QHERy1LNDbbG0HfbsIO2OLE6HV9hzKkM7VYxW9MLgJdQONvcR/ws4tl3j4/GogvqWw9+NQv3s/H1hz1T1YZ8q9Dj9W+4W5jUNlovRTZrk2Eq1hWAc7Jw08ShlUIcsjwR/qjOIGhIvn3dczOnKXv5nZiTJ/se2ApXtTKTT85XJxUV24y2emvEWM6MNpXAWCZiX3N6dy93b/6WK/fPxeQ51Bnk3r32zee1rQB62QKSpiL6MgwOCX743lu4Xy0QUmtW7eeN9SFqNOamc0f97+ressNO9C/ktgZ2h5+wJpngI5EugJsG9z2zQTmftOC465SbuiW4Pdu9YGrXcGb612FOtNmGqx8rFynxlugLnbBLvcHjaxi53VkKWweHv+RTQV/wcg+3D5SFUSB2gvt1sgQ9XD3snjtSLx4uAntLINBnTM185QqrX2XJNPqgC7uqBKttq9CSQLHHJ5R/N4P4Gn/jiYnO+cpRxFz+BYwe2jEamLTkxAVpsvRn8MDUmtA4ZQVz9ejBSIcssaUized6oe19RfmiRpFu/XJENkYcNmTtC/TWion2wArEfTsylR7Nz6eTu7Jtj7MeObJw9Se6kR26CsIyNxDkitgGayLFVbimAYR7dxNYw4dAbMOHna4CFwavigDHuhFC3i3BtVsgZcXalnW28qGAa8kXGI/NxnUBUQaM1AbbspsfYeU+yf3fudlWWT0w26y3lW6Um1/vj8yGZQBmILWOfGXVlnZaG5ZYnfTxcdiyRM2CsoAq1gj/169sy/Vg9Mo0x2YRkcS3fg6qh363PScKBAxOvvIKpu/C3JP4L8t+373Y/fdvRpkKd34JXygMmRcxcObT2JX3LSV2POy85o+PjaQKJKdD0pfVV4zOIVScAcQUfdNiMtTG5AHpQYrtYFt9qV4O+tsaiGsuXdnUnHxtpi8CpMmgbF+LstE2ja6xv4PIhByaIVPheHBrgWuK12q4lRp4ISJpJcZklEPqkvxR2wXL1bYNGGG1iG4rxBW94hX3wIRJZLNJha+mGUycLaJYF7ytBmVCQ0zdolTuDOUdB/VxrNTOASOb6CBeb5cenu1fuQIaRP/xqY/WWuGeJdtlvWSm7iPRaKsxHMOHs/FGuCNkzPrKGNbYK06mzFZFjnT12xGph4VEpBiALV9hACOHhanM/GI98qhtRveuqZGn4JCPESBAh3AnbNjM+BtxaCIgWQZYaixfc3jYpwaakwtEmZOXz4EdiV1MFjqOkmvGhfrWrcVoa4LeFzJ0QXDU6SAmemUjpDMFdE18NSAUGxq4z+R2ZXMpHE3ypRi1Hn35oqTk4z5pRQ+GUzE/q1VDtfjca96tUo4hy7oMFglu6PZrYAShAWqWQGhPcNtWTHwBfGh+EMWV8xuU73Vtf+PjRf5x+ix3g3jV++UAuxPMf+DhUPcmlSVwD28s/d+GSAk6ANic4YebolBDBf34ne7ZZXV4uRZAZUwURdUgpyI5JTnK4pgilhdQY8UEWemyP98F6A0E//60Hph9BGVRQ4VEw1VIJzDH2YFrOgxma+QEVKU+v97661bt5Ye3+O2v3T0tFSvf2ubVHGnbnVvWnZpd0NeWzBfVuiffhRk3VDeWnjNBm3OapEx7+zLd1xdO+obuRNubEQH6YlFsgKRZ8YE9MySDJqCWf59nA3mBUQfD7UANTuME6wj/cb3Kzxj89jwPAAOb0sJGGmEA+/P3m6dMWEwg9v3AJYOEjTStBc20/jTP5/ypWRQOlJ+D2h++vv/+57/CCNcbk93s33u6+dVPnI8muYPLEpEVWwcUGnCS+HPLFI/nIe4Cqq3hKRdS5km7AwM1AZHU/VHYjqtqVQYR5yYHwMH4br0yvTEclAyGhf9BgxHYORom3O6ZuAlsHdyIDQ409FAhqePe3ZdApJFIwLoQcuwaKixrGEx+PbfwyqQj+rSFlSRldf0MIECaSgeWGwSgN1qABkBCN2gfQG1iKcLtYi3PYj6w9fSmmESC5CCQrzBjQx+oTOlsQS9FS8fRccpN4Qo7Tlqt/ZLrj/J97DsA2McmNUJhAKxrXcjkLBbvtbAVvKCzTMMALQCFVjr/q1xrG5gvb4isvugm9HW684FxigeiavTYpiM+PJPH/HVZje6wzgf/GmTxurRsYv5DRhFy6yO88Tx+gSa2qnKF4AODkIleIcRdW19DsBJq1KAdwLsvFitmarBa2t0/jUBDZewKqI62PAJ5IPDkryzoqdUeyGp9WsFA8DuksReUJZ5fm5mcOHiDY1QNULkFlE2k2e22qEH53h0JYVZ4hWin69dpClP1yRngvaLqJ43X1HH6wh/3QJbrW9uM/OQ5qtulTNjVSu62lGvFt4wEqxIH4ikHlIePhmFADU6eIGBG+6frT1hIISxxW0qCw7Dr0KYs45uCF8+xfhyeZcdrY3bmJ0XQWBNrh7rdn6EIf7jjCOtemRoyPaJaGO66VxGvQPXFf9k+0OSOST6NZX0I0H/elnyVfKidfKjgvHZh46RV+faewZ/iBoNhatVmNuDda5TKkDslYLxNQDbvS0N+7fkci27jqWmBcAJ9JvgnNGwAcar54t3vpb9wXPh7YO5B/+y+3xN5p855Cykbeu45vNSQ7RVIQ+3AYVALI5g1rMZx+QYs6OIyAfJ/g/EukVu3SgRQRjMzEhH2cWwLFXkYKqykz/HZBUqugPwUv4U4MoEXAVvTkPqoekvOTmPJZS5EQKv1bKwG9pL+KaF2ltRqplvDXFaVAC5s6exNI1twIQd2oLqSbaLzyJ8+1uQnpJQnZH3yeXEOx3PEncjMr0rxOVA9UaXsPhfyoa15DdAjW8sRI6tMUzmzatB/hzJZkyTEpbI5EBi0BvKHSMNPI5GvNpC8prUWH9+Xt7jsfb/zyCSUddvZ5C8V8BY1FxxZalWYLYSEnj8xqEFggu4jKQVipwr/sk4kJAiWdmMDKk6+Az1m+gutHw5KHXIzSN5xTMvlC6IDFeE/pGf2wS17lOLS0b2rPwcnDuf1Hpw/PTh3el6lUK1rYDe4lre88WoYSalAuAvoTFBPJinciWXttueHLrMGHvI+9mpiYJkPsxESGJ6pBYCc2SDU3UR9WSwWan+V6vuC5oTn4jE77Ohfovlkb53LW//Zo/dHHG0/urD36pnvxDNfMCa9Hdf+hJsTdzlrdXvcWqtVmEjBli2CYsJoSjOp7l6+s335Im4kJ3d0rd6TnWffK+c3TgL7KrmtyRmIXXqHqUCO68LHAxMUVdtcAAgHeObFGvlwryc2xXK2iwxc9RY8v/iskVaNP0V7CHypzdFb69mAEPGG0YJZIsiAK5zH6M+HkoEZojs/k7p380m/MxdjvI4iDiH8DT7t7d9zZvt0ZTaedpEP8NzVlqu2FPOsihhfUgC1AgAv1nT8VgwaTzO6duTI8r4NVKVbDtlk7acqJxv60JjT2bdvyQk3VUfYK7KTHGjWPcTIw7hy7VvEPMWTWxPcdNpwcawf+Szhj2BxOv2yjE1g0cO+OQdRDwmk1vDoP9s43Gieq9UKkJgF3+mKrTiFmr+O/S40ZnvymXm3iccpAA3zbl/Mnkzzqwh0dU88wHh2gr9mT8dHd4zvS46HpcZJJgMZo7EyuVBtN6C3kDWe1fS+VZv8bnWhTyml+zDBvKHKlCcpLhihuaPLHB9VWs9bCc7q94B3fXolKzMNOMpgboAwUeKkNI8shULDzUhs3IlrBMfH1kleHp7hGuUL1RAVULvgEeAb5gFV0ZOro/tzs5NGXp2ZDWtbiAZeGcURJWCowTbbFmjF5SSxaB3I3DJa0Y1yL7EUY7mZzaYHvLPaDdVWxt3peMtNRmH/gU2+hwCn+csfSaZ5UjI27GYOqUc/Ml9vmXMw/hS7FE6Ic9Cw+9BzaVUOX32gM2dHFYXPl1CFZZIewCSp54cpaa0HEcLHRjEkfGE6Joa3twBCERPtJW7QG2juXzop5nRud2C2kjOYimJ/n9GRMkEPNSOekt1rxmtsblXLtGVoeMv2lqSmFF+zOLtYmXO5zKyYBRfzFZuyNYi02wvoYlwmk4A9Y1DGpzUNbBbvpUE7S+1qGvN1L1eiukq7mOONgeUbZgBrkFa88Kd5PzDe2oQ6EHSpq09CYxtj1FGMLB4BM/DcA9qJf53ZM7MzGE6joEOMkge6oh+d5xsO7Ox2PJ/wpfmKyh6AdoTtlbBwlGtl1SYCDtyagnHCJqR9gDAKigOs+hXhrgCuJLQPEGK5OWGMkmO8ZiOuFMI9zf+ve/TWTJdfu/7l76fLG6qo/8+viSpV8j2Wr9CTmkmaT8Ry9v7+7efpjmbOVze9cDNBqK60yWwvozJyLJD7LU7G2yvSYYGdaZYA49DCTayOe1VQ32HIgbkHzz8BKMjTeOYoVgjLCu7wAEatN2LM+YGSF7DeH3XvNO5UVUYeURBQTfyQoJIDAAOBCYmdIAijHzTQkhHzS8ASqt6agx6thz+TM1KGDh6dmIjX0yAuan/uEd34aRVM85wa2ijtdDDpukccBAjtf94iCyxqCExyUWC58C5De5+8y0YUWefPMpfUnq5Bf4+OH3XNneXjNmfMU1kQPybOdPeldfKt75SLbZVS2+5uLFJINQUC6H4LQoN/8HMHxN0/f2Hh6bu3+14x/7a7+oXf+HuThXf09KyP7AW2c+auz0+n95RZ4PNy5DJqUm6e7t284484rxT1QO1w7rcaKZqXi+dEz4TeEMirLjc8o3oKXK6ETmFcHqKMK3ra0uRGids/0scP7cocnEby2Vaixp3hZd9AoqjFoAeaM7kKAb0QOFNjgjEMtIutlLZtw9h6aPrZv/6HJo1O5qZ8e1KyXysoa5OznQvlGrVvEn2ICVEj8HNspjmYeIgb6Th0muwflPHwNATZJPulzHOqUd1CA4jLqnastNjPEKMeo2KhWDIgy8t9g6oPKE84onhdq6QeMVQnhwRXdgCsgw1jVGOOrqYUxrYUxuDoksc+ViwsZ+mhH1lohLlexltGWbc4t1twsZeWQD41rQ+RTAf1DjINGEucVDyqVuSee4zB5sfvOx06bKzOHq68NZzvb5Z9cahkG7fLFI0wy2fz0g+6X19gRUUVInGGfOOUG+8rvWw1KxXc3njxZu//l2pNLvat3VUkQYaDcK+wnnDc8u+o1n4Zhpd795D47pVK9qw/IwYO998gxVZwvPGvgJRl9CADzX15X3xiLgl0p7oHTjhnL1/98Dfozu/cIRCmuPf5EleNLzkq4fOrtBNFUCzEKhPTLTUgiqfLCA9LEXxiNAXuUbp2PoLToF6YASWm6XJwuy9MXFEXXHlvSldMyHDwCwOndy9e7Fz+AVO43/0zTz4MqL14gyqsTXEp+27vz/sa3vzS0ENoARBdoBLKbTHrO+tI49Acr+Ddei4Em58R9CFh1fBjh6FJmGzoCsKwwFONTOT7w0F5xRemXpFS31Lw6ozllsKDnGL8NQaXcDUQkQWgwctzMIZF9jQmHXgmQ4pr1aikW7fBkAjLzSq3Jz0lk3Xskwh8rgiVApyw8dRt3f7n2+LrfIUt34ilYVl5ruK/Pgj8wkPtvYL71EWxgzkXtUcPNBoFl6T3mb8vaw2Dh//bsOZqb+dnM3tlDfROMhgMbGLtJ1ZgIJkYzehXnIWFRIer+SQskUfQBL6HnD18a9PzBtepefpvR9r4xQ4a05pt0zKXFhNRUsXZ8PMU2b06RZ7YfgR+Gzch3qw8WKR6hgHAXFuquwLKRdfbziOXWubNw7dCmpDtEjJitAqlDBTsp4r9HdwmXDCwbCN56hiNCIkHBSIDHxQRtWxn2W5FrAWmb9lG/cGja5qBQYOwBE1c6mTYs0DAt0HDCGU6C2gjhU+wTT97zHVcXeLADU7OQ2mIm24c+qukw07HwAzjBu5jgKRMnxOx04lGu7WztczSGGJmYKtUToRSWomXF8kL2rM1H1zdWbztLrzub1z/unr9G1x+wErrggdcf+N5geq4weiyyRQSJ8gA0V4N2tCItCxE9jz4rsikJm9t3uwvRvbt6vffBA+cAr2HM0XAMhizANhIaF/UhouGx3AK74E8UC01AHWt34s90ecgsGs9xg6gB9LlHKDjHxkT4uzHQfRIk4FoLEvYGwHl8NFaiE5HjCcETtQAkC+3yjz+hhAygHKZnwFa7NhQaERmHmmH0Ifk9sWdsf3dXb0iZVwXkcBY87ZD7DDDMH/5+48mnva+esi3xz8cXHCckY7EetLUFeJY66bLIjCw2j9o7epBViP9svr7MWOKGl5qsL2NGNggpt6c/6rt3ZC6kPsgosIcjQXnEkpMGKINfbwHHSFSTqlVrMdwbJt6miiWiDfaC2mHSl/FZD1SQMPsK69RZtBZKgkN65wP1eAaYTeUrgKYOAXPcHhlReDxWKjQhO9LRsXtEW+q3/qTKOqXWlMeSBoEi8z1MZ4x+y5SwsXv+HlwaBF955T0pVG3cu9P99le6Fit4mZjONAE3GfS4kMJWQkmOmsuFXclsd95g7BjUwn4k+ZToNfmlDv6J7rahlwxpQ6yakVmpT2vyorM0GajD7vBBAUk6OIumL/wJvXSOVE949RlImOj0Lny2cesiW5cIDSQQ0AffcLxL1CZ0P/64e+XS+vt/3bjzJ/pYJL9+O6DPGH4RNGeYoDZfSB5goprj7i0BGkbv3r3ulfOgrrz8R3c4wMIMAwJXYnZ2/55cg7GBlUIjgXkPc2zK+BN6MBxsczSV2um86eyv1qfyiyvJ6YVfeItNpw3CbSnlnfSc5OsOGHAdZah1RsccaUZlxKbipYoVjGpx0MTLHrqgCJzYvl1ZYHFsrjMc0BMlq87hY4ec5Aln+KW2Zj3tJNifFvspPvdZUOmZYUPtzM9Xhp3htmZI7Qw7HeWkdjJfKVcLOdAXlbzjXglUhmB8krg0deKLIcnLUinPqDGXMUiViY9QnemllthugQwXdfdVfDzfGJlg/8VS2+LoaEwVA/eXeoUbE6h4BohTCn1bGuTCFRvBhjkec104HkAnDJtM2108OboLjkwpv7KUK5XJplBbrKAZulYpormh4Y3nRuVvY/Rbw9vhdgC5AjsRcNIfpTD7HZgXIH/8JPrbHD+JhRfKxVH+E/9eGt21iD/LeHzL1eMLSHZOgjzqGt7+O5Bf2CHbxZuKNbCAXS+9AT3vOP+Tv8RRj4nYjQjlhaSAWjxGIUkuccnjxXpT2vibeUYT62ZshmYAj4rEsPlcrb93p/uHX649eYrM81MmCPZuPpSyH6GDoXpSvmTsHPHaIGUc32G4yzBx5ThEhLMdYHevwDnktlI2yu1s77ZK3naQl1nh7bxwPyPvM4U6wyVuuKOVoTowz1oN87gA4hOY5f3wr+gY3SLQVzfCC8EvVgbSDLrahNmjGXgaSfROouVwnHatlG/C5cFmp+Sx6xEEVqqc9w9kbX0NjCpBKOx9fqv70TXhsdwWxVBHjS3yZEemstqn7DDUHFblBn4CBz/FoydzrxeKjUVXB9jRZFuA0xHirdL0FZcrwBGbYj2y1EpM5/Acfmld5H+QgFqyeqtM+m/QGgTkCKvWTht1BNy/rkJz5ytu6hfVYiWml3W24Ys+CrSAl8lAniWhndfyjWpHISi5WxwLv9PhGRcjpaTKqbhpcdDoBa7+5JFZCNGE4FL+NAX2TBhTLORdClwQl0vVhZg7Qh/zvUYyAghNyDw0fsjYh4K3MJ+i/synqvXlGHv45nzjzRfj7pAO+IpOg9SINX+gHrannEWW3FfZLQ1tNLalRtrUAXC+6hdyx29yKxWEmQz0baDJ4C906opukZ7klevC46fOFpF1HVeyX2eD+TfMKTh29GADuBVjBnijfKBagJzytHl1iiLYoWylyv550V+OsZXsx0Gb9sY3V/xv3Pfizi8Ucnwn1r1atVHEoGG4nMkZcZENuekJczdQkIyjzTJ7UAehz9USs1B1KXYZukNGrrzw1QmWxi0rcmItNczS8MirsyVgNdgKw3t3S2lqqIKkS6mIyjU1p2ykuL9lTqFyDZNuwDIVj3sp9l4ZZwV7HKMzBkesxA8YnK/teqGErDrh/HTy8CvT+3I/mvpZbubA5NjOXXrsVjPP2hbfBmPe1fJhbBc7b84ctJPJlwu7xh0gTl4huXAqgzdJ1hE9a/NGp48efPng4Y7TFovfwahEgedVK1YqbKURLuwIj08Hl7XWST5pI/yvYpm9So74nq6w7rK7XD2344QVKxOCQvn6NV9hL5NHILldsXlqwtkJaD/2SkTvRrDMoBWOssriQya+NTAM4I6B2kK8ZmEZQFGIuzIhZkV5F7FXIsOhWhD1Oh4AuUO6QjizYdnRtC8IolaHpY2Hfru4ApGAiE0dD6fW9hyU/qwUfCIGSkcJZiwAfrjEZHcw5/w0X3mlWnDI94hnoyQNDXBxdx6QYVvgFEdoei0Y3LxfAxjiOCFLMUbLA79wTGZpiqgCDTyGgqqWWncpX4YgTnQx07c8SlTa38lSM3CvHM/Xi3naQuSRg5WzDiec5GhgpWW+erdNjXaSJ3eNH2/zWjqu7y7UvcEh7mExz1gbFBHzjJ+t0sXFY/4NDjGgGxc+rRaHY+6uasGEqJZa5QoxqEWvVBD8Jk0aPIEaNRda900XXOOtuS7Ah5VXiH6sO7gPMz4Bjx/4s1UvUU3qufTOTWfjKeGXDhUYxz0Mw4F8nd02nyXGYYuaR7N8toNiKd/RZMuhMJHewytr978k48jm6be7V85TtCXFenR/cxHdZ8CpAGUlGVtiYnARaANtJi3Eh8Rt4fqrz2fGRX8qi1Oy11zcXm0kuSAWnf0k1CvZYGYEONKrc5PJn+ey26Bt9LKJm52kLN4clRA3xLA7Pzwct4hEVEYIQ50h4QtPSyheo+nrx1NHZw5OH87tnd43BZ56WrQrAAZJybPMTgDrFJEt9+T3d+V2jSP4l17ZwX3shucm6zZclexwYTQQBnK5plcKBw7zQ0Tlk29k4Z90cncyOwLSNu94NNig2DtnyeEK0djevwOaTtxNbB8pQzgPMdsuAszoJv/xkRnT/6fC2BiDYs+NT+xEbOwFd/5kepSkv5q2OUCzsVSsl0+wm2I7Y4DgP0ZiGpJNnvEWGakA0NHkiBs9IG7JR43L2sOzzrGp/QcdKu9ABVwZf+Y86WtJR8OHjFmKHGNKjKFxvQgjZa/lWg1AMHG3QwgU6+dS3fOc/3AYj4T+hWPjzsiIMxbVUSzp8Nn9r4eb175md9TGN3/DOsg1jTq6ee6d3vvf0ieaS7XQYLKNGVBq6t71XA8ZrSPiddKlBAQ0G9RGcQ6hn6Aor8cBWXlN2RMVOUioiCKrRyZ4S8rRBx0Gu+fOdm+f4zAxQjkkS3Ysrr0yFrdelqgIIuYwzqMYeYK8eES4ny80kf3JiSp7DDYddvU3JAo5b8pI1yU7+VxxLtEoQrrIWvdAxcUW0xS0Bk44bSottAQDYhzmTSHceAsecEFsVxZRw4ATWai9tpx8veXVMWYr+ROKKcu82N6HHzc6YcyEVbVIR7hMvdEF2vkFXU6IIdQe3ChESlPb/ncumcUwEr2PRjAJlkwt16utWoyciakd5XpD9ylhv4EebwdcpoiKzcNpSb1t5IHo67rHj6NRA/nk6xpNNHrt8MWBD+4mwzEaUHPtgEET6Sog0qCrDLnJrK9e6/3tKgAWL70eCrYqsuYVRFczNgZjSFl8K4AIaSmWcYJq3dBxD0UOWSlRI/WeuoYZ/IZIySzux97lK2vffgis1JnH3dUHnL60/R0HGcM3jWGYesWlwLBtIEEEvmoStUCrAdOfuPHX7r9Hbk/oywc13f3r+qM/Dxj0S1EZHGyChqVhggmtNSPmItAhh8m0lDIRMprzrB+ad2BfVC2X1Zmi0n3sOPLO1pvSEJx4vxrW1sFHGxtGO/gh/JY6grxisCMWbbeadxg5UR1lMoz9cOLVNyfiMQHtubMTn29sm4/NNBnhLc/HkZnlXeT6OMtOodtXDqGxQsiSs1vq0qvUILu32TXcgN7MbJvQO4hWTWxR75FeH/1k94lZMTyGgLy+dQklBFQTaYhDq8vGnbPd818404wuz8wccHpf/hHSpKBpDjDq0G7OJXvaqPgVOriR9K9BIxApb7ZqkPicosvbcFygKyQqoJUecmZD5zpxfZOzn16l4RkqDKHcnDx4aGzP5GGhK/xFHhhIVBLu3p0UuaPZwhHYjKvVupCv5MhzQbN3mqa5ylLT1XDp4E/UAaAy3m3CfdOINrz1w6GDOrGaOQhmy5SZMF6EGci69h4Va7xVrVvymTB9uDvx15nn7Jqo1961MNEArbN8A60+3by26oghIniGqJRtnP1srcb2AKgGfk3OPN27b61/apA5ujO0fRDjaqCGCTIY3ClDPrtaUNcVtGaYDr1boKBLMCq2t1I8+8iAdFSMKej73pcpjLBdGWqzRoTeDL1BSOFL9oKgsRxmQAwuSWGxOPSm6ZHtvwmiyhrpU6Q7kT4Vwawl5MqNRpKwdbGiAG9pYSRXp6ZHmlfCEyHJtC8yD1Kw8bgvZ3efEYfNIFnr+YUpZnJrhlRfQsFgHwaSTgbS4yrTbKQid2u7KcTeSwhxfB19qdHJ/Q+FUEqlG6dkDbTLeKL2QHqrePQ2GOHV9t96PtHOj/Wuk76RhJ4r25BoBJNgYwtNEQHcMqpM0DGvFv+MCqWF4IH24i9HwD24HsNO1KqlvAIXkxdWgA7bzA88ORxQ41iwRMKxI7JyBoYXXsk3csLDi+//QAOgJvF9g58Ao+Bk+Fdz9CYrTQCkQuHOIsCVMNYmt29q/9ThmSn4OXns0Kz06piwxPMiHwLKR6Om+JAv23Pdtr8FYiP4nFLm3AnHpXsRoAivPkWCwtg/8Y6g4inEkqwBJyGo8hS8o5yQEG999a7bmYPumPp4zE3NhLne1a/hE5xirlJXFXHQPJ4YZceudPofp98aTZfxSh8bX3F95JmNDLeZcJoXMbJttDT+8/H5NjTLfrkw1+aT1smGecUzmsHqIyeGuVHQHyCfm06MdSK76/v6+525RnmlcCL7Q9dvBBMd1izySvnLm0+Ir+IDmcVopGACIHT/3iePu48vA6dz9XwwbkJtHNEVFXcqP4Q9RQvoC5Pkp0Kdb5AQInU8hYWJGbw5kvQDQXxqp5or1cqOJHf3CwPnkcrCAb3NUDMv+2bk8OinkOyr8eMgZUqhJ6mYdUCK3Q5GkckeRtxeOhWY/slhzOwiy4WkBUFKwOPn+Y2ScSF1FujXGHXOuAnuUgTwNmzO6HFDwIVg+YbX5CQk5vJ8ynjn84FJ4ggUg2QaGaMH5SfMPaR9leUXhi4MDfEwAnZ0Abu7CS4fB6dj+nWQovmgj3Stkn5X0VuggijVxzRUjkCOm7O/gwwY7eBNoFyLvQIE62v1D8T+63b3Z0gKyV1KeRJDEGw3r3/V/fYWKWbWH3+w8e2v/UIudLAKoAs+ITJfqRJKqfn8eNG81Kj4AF1DlZQD1SL5PV70JVh4BgcYuPZs7i9sSy8jATecX3Q52vyS9gMXqwJilnmgaZwJXjLuA63UF5jXbVYlcB+BCHzn20EEK5DvKY998+8B/7r7NLFwxKTaK4plH0ypjpeQ50f4/l/AvgCXhy7xc6/O1+cr2RFQa2HzAgohT9cwDFnUw/YhMX8eAGrhs7nRrMrT5pCpVRgSEhDZn2S8iNB+uR0hZMCtSPAhYJIEMo9zL62Pum4mVZfeibh/4nggoKCa+xRe5C+oVHONJNlqU0B0NLNmLETro7z+sIDCWwrQbVu2ZJos8acYXhgYn34rNUj6ENeSdgXZnTDIwK4p8I565eNObH4GDSGGS4bwFWTszZyqOGsRiLQOWboSf3ZJDrNlByZukFL8FEn9DhD4S/c3njyJDGkPnn8lVqio4vXPHm3+7rY4lHQUIWUfpkgHRGd2YmXD0u8CYonOfLP26AN2gnvv3NZPcFDNaI8G25Lw5INaJmgfN2j8kD0GkGhhdRg2LBUcFrp79wbmZCcEbwt6i5gZjVTxWikge7ifjGY0xMt0wsLMNM5LCqx6eJlditVFWBtss95aCG/W53YUE6rbgHyLQWS4v4LLrmLx1VaqLut1sZeSRh2afjnM/w6bbLImFWbDjrSM8tBriFKwYC2/qLaAXAkP+FaIxstsZUky1TXMYWQfG1zY2tiCfJgNmtdyP/OjBm6m6rKuE7pmIPCY6xkKWmrpXK5QXczl4lpJFO/zvEjM5SeXjarCHjYy7g9dKXtndLM/ItA1MnMqk5i2kYHANcyVf71VbWIsVrOeX1oqLiZxBzO2Fp6JWFeULwDljgLIKBEhf5ZstFi5kxris5KuAFJjh2Lnk+ID3HBJPn1E1/PsTj6VPF4UwT9Milb9LhTzy5UqfaqFdeot5Xi3ktUaWdzkg8USLymjQJMEf4DPEGEPf2NCp4caTbah696JvAHi6ubE/DSLmJZXPcDQNXiAU5lcbuXrBYEDY13LZLJQha3CCq14pVrGxagvDPx0I4t5ZTpQVOqQ1xxuOFOVxfqpWtPZfHt1ffWv0eVJpqT9n3Ep6xOX16jK3nt/6l6+tnnjMjj8oRWse/kdul7I3YiM993Tj6MbqtWrCL6h9mPMlX4rpL5ebLH2yxAbQU1TeDOPj+W5PR/0bp3v21CzulgtNeQQNs79efP0BQKT7D683L18T6W9HR51xpwdzvhwdKXmrqZquzc/X//w642nv6cQvZt3uxcfAlLC0yfddz7pfXCu++W1fz7+EDPCdC//uXf92/XbD+mr6LaMJPXGfGnEWeQx0LJCC5j8SEVG6P9xjH9f9laFiZ+Q+PYJM/3BVttT2Q8SgRwG8UEmCNMzQHYNMNghUq5cbpmTnODN12/8ihKnI1CFyMgSuYkURbEthC08nqIT/aHuW5wdnKHIqPaECj8faLY4PDY/1JgMRk94Bi6ZwSQwHwqlMI9RPXex97vPwY1j9e8DTyVvX+xS3gFU4tKiUGqb3tW7ABaH6ULpLXWCUofyJtjdgZZN2VC51Wwxqnwq551cLLUaAGBDvlPy+0B/2LOkPEhRhO/jP63ffFcPAmWED71cyDnFjW5C3msRTaw9es+x+1tzcscmhPD5NW+g6NmGS9RGOTgzbqoPFT1Bjs5gaxOcFVISljCReAgwMPgiQIFAP094C3VwdpVTQRsMwyucn3gL3LWi+zt0FgZwgmR61Fn/cLX75KobUS88THL0dk6mb1+Cmi/foe2+/ujL3k2ABnb2sk8XGL+9ceettQefbt56ED2zigNQHJUr6BejFGwK3KzGgBEhG6TGQvKNakV1eOPTs+sffuDIt+yU/Wn9i9/B7fLxx9E1loplRlSXF1RdKNEQCBATCwn5p3vl/MbqLfZw83dXQMV36erak0vOy+glnHY2bn3OLqq1+5fY280/fBTdIKNGKIVHbHICOXOQE3K6v36y9uh27/6ZzQ+/Afn2/c97f39r89zlPpuaECkMWi/39s6EM8r+25HGfGDy9GK1m+fO9T65R2QmugmJ+8KulVoSddJyBBoe1L2/bdz7pXNs3xGHeKGNi7/sfvi1YifGxtPpdJL9O7qTUU/AtRiIRpqta+w2jpdDHFVrOfEm/Fax91jefrTW65/9Rna5++HD7uoNNn2gXiU2j81ncnznoD1u1ZKYUcLsbACPafAuS5Ap2raOQpjCnUnHeNDeQbTiv65/cJoi+4dhIeyaxviE6aOzuSNHp2en904fmtFdXoJjWGKDaEPBDu5FsRWX3Pbh6X1TCOc8gxZX+CbhIHrLzHC8w7clb71KuWYUtcYf0IqWQifGv0pJx4CMKVGhTUt+pUPoCN2I8uOIB4blkb7CxlI5a4/OYGDFezowD+zM+++v3X/YfXqme+sLRpeNsAnZEQXfAMpV/SldvaTs9A8OFK4ogYZ3VDEIAOPn6Ne51mOoxOiYaAm0AMGJCe2MLvWG90ld61oXtKLWnujNcHYEuwGKaB6mpHWQAvooeOmZmFa5Itx7XCRp8z3mOdt8TzH92LPxyL4a8EDHQzceZ6DQMVlNHZW1byxjGGbWOPMo6AMb6BDQbUySCZFkSpHUvXIROOCL54AS+wRAmeSOb0Zd+Bmk/xQFJmQ7n5zVsQ4IAZoGH48uRtB4/COBCgeda78kaOsg5W191h7STrD3EGu0HiLMeEGSv91hzXLgZPSdxmvrGoSO39XMPOzap9pp53WhFVT7wrQyBJBOiOJrg4hZBhZAJVGaZisSotFhiXzonzmu8TGIjEappZ5m4GnVXCvc6BkUTdORUS0FZjMAsTtg70KGilkENaVW0HnGR5ze+3zj0hXSanEJCNkx0lWtP/oVY9Ulbiypsehj2r+kzAramQLdkro121Ah+ky/nfTB8GL+92pqbI6T+gg3P/r92sPbaw9/w5VwGpXQV8aikOt7pYmtQIj24gsF4AgMM7kJaks4+FWjbVWzTsGED0SAuJiAXLj/EgrswUEG+q+6vNUYW7UcMMwJy/CBm8aX4fetxiff/7S7+uQ7GzTjdvNNRmv4xwnyhNvmuDnKgxOYD3zPyDCYdI8endqXA9Z5JoJDbdarv8hXkOH+x+m3GNNV8Uol/JMTkuV6bZH+Hmw8KB2Hcn5kZgnvDpVWLeH3dpaT5OOB+M2ATSeC6eTVqi74C1t7g0qI3PLCc12XNDl9Lkqh7gi5JX0TZr0f8Rvub+MfwHd7LcIoV/IN2sMANcs2tNcqFshbqooo2PA3+RCmQzkahQoIGhxSrmAwHXcAdIS3U/FkqnZKYY5ajhvEhOIpsbqC1l0VuqpHseaS6I66cwz8KAN1hZ4vU93WvXLJ7x7KpqBVzjdei6Wr6e99L26NGe8nq/oWxIJ6Gy7HRqYfsLSNW7aPDbATyjLoIzArCTIN/DUy5vUcfBQbJPWDYOepdMyrYL5ZKzRc38FiFmhhcjWbEo9jW6lT2XQn/I7a9HxLtdrrHDA5jBk1KzYM3i84dXa4lcapRgpy48R2bKXDwoDu943HpznGTbZkP7YyyST8m5VbwdXtadf/XQK+VbIfsiC3xwIQBAlnanq/DS1Rc6iar4C30eUPet+c75tuJOy8D+S90BlgpkOWyqzXvtVC0mZr/HwQ6AbdXKwNWvVPxs62eItZlF3sEpNmpj7tK9WdvUUdmXVocNx7HRNBmww/MIJFVWjbY4EtFrGver+9tPbkJiRauv9l74Mvt7K7KIG80hEMsIVkSvmAcP//2aHp54jjOy9GmlL+ZSyYuqBpzaMgaKYwn4k8pdZ71+iX/0oNu6yNQoOkFVl//LB799fr7/5l/Yt3N648AR8QFIM3Vu92n1zd6mYJuC5Zk6JQxhdMGSoSHsTRcHB4cvbgj6dULoL9B6cO7UNWVHAbVSiD/HEMaxF8xOzRyf37D+61pQ+Rl+Bo5IhC89BG3ZDop+bbKCvVEzl8Qavsi3+0kju/IyQdkJV8q0FgRWQfIjCGQLUigkp8H3pq0B7j8PwM974iNp0Uv6DqQPz+7oefbP7ho+7DTxH9+yLYvm+83X3rZnBD2EmeSsnoVUSwjZ66Nx7vOJBEVyCEUKsA1WH07qNzXIjg7h+AYIUdDfYDw8/MLEHUUnjn/MmA1r+443BnB6ctNx8HQOtYLg5poIMwB2hs0GxBikoS5qD8bm64VRPJIzGkDlLlAKFSTVEAILfkBWoELUigTnho1orpdp6l3uCcqRyzqEtxHG4SbbdqHfgD7Y9taMg/dUZKxvVHv+6u3vBnL4LDE8yX0i+tc7AOQRfsRKL/kZQepfbULsT9Dnq+ySXVrAmfUTUD1ODzO/UjNOPLHL18tq759T16TtpINUQ/5UpIXjZjcUJkQYrGwV5keApbVDtlDBXWIKsYoVfS93bQL8NpiwtHFI359Fpg1v7sN34E1bBrkbx3/Xm02LOBF0o5+05YmQ7Ikcg/yJK4KTBJgnRQQawCwFixjvk+KP+QqISU1Gzxc/Qh72cw4NrkMk5oLA5hzGD98QRvL0M//Bcxm9HFYslDTbbJIw0yM+QQ7T8T7NngVegu0YH5fQ7eQ9y8FBHSKJ506HYlNyN2wULeHbSxcF+ktaervfcfkBsUeNqhU1Lw0rPxNYKj1hHzJP6E4KkTHERgAES9Zr5OMYz5Oj0xegBo1ikK0UjB1T2FrYPGKqCG9MXFwCxw2eT2Xze+/pPjtNnniFHImsvAsBrNAhMGtMyHYqhjO3c6g6whUZ9RCHhgn+dQCZjL0Xc58GnP5fg6UyzE0P8DVPuEHrOqAwA=
__HRULES_BACKEND_END__
