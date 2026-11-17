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
f42236160869a574bfe851e718ab36d8decee5189c2e73eceaacc47d9d1563fb
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
__HRULES_BACKEND_END__
