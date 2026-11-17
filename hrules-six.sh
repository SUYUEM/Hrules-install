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
7d06d0be66964cf23b1c61bb5d219d0141b2fe6db260c1abe006b3219220f359
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
__HRULES_BACKEND_END__
