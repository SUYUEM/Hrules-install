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
3e7e26abcc44ff73703f0b3dc9f2be87f2e9bc8c2119216f21823627e2117d0e
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
__HRULES_BACKEND_END__
