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
0db32a7b406deaf188e702e5ce082d861668d58142eacd6e07a1877eb26279ca
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
__HRULES_BACKEND_END__
