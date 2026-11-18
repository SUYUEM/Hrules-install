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
72535b0dd957ef781c84bc875a0de94b36141bb8bc636e97fe6457d70fe4cbfb
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
__HRULES_BACKEND_END__
