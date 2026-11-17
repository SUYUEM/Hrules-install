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
f4f1b00e3d132057f984645943e7f2fe3ed38021869a7f423d4e5b58d1fce68a
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
__HRULES_BACKEND_END__
