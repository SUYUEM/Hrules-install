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
06e73467e49d81d9669be9cc96c6b41623eb52f9d4055b75959ffe3964b157ff
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
__HRULES_BACKEND_END__
