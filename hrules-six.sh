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
231578a81ceb5ccc51c8419eb299b1eebe049b03ece09a17ed123801a7babfde
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
__HRULES_BACKEND_END__
