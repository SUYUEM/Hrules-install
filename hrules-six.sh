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
5f9f549ddaa0611c3a42e63deb1791953e2c43b5873ce5e7cb856f3124e16158
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
__HRULES_BACKEND_END__
