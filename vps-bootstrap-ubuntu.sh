#!/usr/bin/env bash
#
# Universal VPS Setup Script — Ubuntu 24.04 LTS (Noble)
#
set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly UBUNTU_CODENAME="noble"
readonly EXPECTED_UBUNTU_VERSION="24.04"
readonly LOG_FILE="/var/log/vps-setup-ubuntu24.log"
readonly SUMMARY_FILE="/root/.vps-setup-summary"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      echo "Usage: $0 [--dry-run]"
      echo "  --dry-run   режим просмотра (без изменений в системе, кроме файла лога)"
      exit 0
      ;;
  esac
done

# Для перезапуска внутри tmux с теми же аргументами (--dry-run и т.д.)
BOOTSTRAP_ARGS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()     { echo -e "${RED}[ERR ]${NC} $*" >&2; }

die() { log_err "$*"; exit 1; }

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

require_root() {
  [[ "${EUID:-0}" -eq 0 ]] || die "Запустите от root: sudo bash $0"
}

maybe_reexec_tmux() {
  [[ "${DRY_RUN}" == "1" ]] && return 0
  [[ -n "${TMUX:-}" ]] && return 0
  [[ "${VPS_BOOTSTRAP_IN_TMUX:-}" == "1" ]] && return 0
  log_warn "Длительная установка: не закрывайте SSH-сессию до завершения скрипта."
  prompt_yn "Запустить сценарий в tmux (сессия vps-bootstrap; после обрыва: tmux attach -t vps-bootstrap)?" y || return 0
  local script_path
  script_path=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
  if ! command -v tmux &>/dev/null; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
  fi
  export VPS_BOOTSTRAP_IN_TMUX=1
  exec tmux new-session -A -s vps-bootstrap bash "$script_path" "${BOOTSTRAP_ARGS[@]}"
}

setup_logging() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}" 2>/dev/null || true
  fi
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}" 2>/dev/null || true
  chmod 640 "${LOG_FILE}" 2>/dev/null || true
  exec > >(tee -a "${LOG_FILE}") 2>&1
  echo "===== VPS setup start $(date -Is) dry_run=${DRY_RUN} pid=$$ ====="
}

check_ubuntu_release() {
  [[ -f /etc/os-release ]] || die "Не найден /etc/os-release"
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Скрипт рассчитан на Ubuntu (сейчас: ${ID:-unknown})"
  [[ "${VERSION_ID:-}" == "${EXPECTED_UBUNTU_VERSION}" ]] || \
    log_warn "Ожидался Ubuntu ${EXPECTED_UBUNTU_VERSION}; у вас ${PRETTY_NAME:-$VERSION_ID}. Продолжайте на свой риск."
}

prompt_yn() {
  local def="${2:-n}"
  local p="[y/N]"
  [[ "$def" == "y" ]] && p="[Y/n]"
  local ans
  read -r -p "$1 $p " ans || true
  ans="${ans:-$def}"
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

read_nonempty() {
  local var="$1" prompt="$2"
  local v
  while true; do
    read -r -p "$prompt" v || true
    v="${v//[[:space:]]/}"
    [[ -n "$v" ]] && { printf -v "$var" '%s' "$v"; return 0; }
    log_warn "Пустое значение недопустимо."
  done
}

read_secret_twice() {
  local var="$1" prompt="$2"
  local a b
  while true; do
    read -r -s -p "$prompt" a; echo
    read -r -s -p "Повторите пароль: " b; echo
    [[ "$a" == "$b" ]] && [[ -n "$a" ]] && { printf -v "$var" '%s' "$a"; return 0; }
    log_warn "Пароли не совпадают или пусты."
  done
}

apt_install() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] apt-get install -y --no-install-recommends $*"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

fail2ban_write_jail() {
  local port_spec="$1"
  install -d /etc/fail2ban/jail.d
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] записать fail2ban jail port=${port_spec}"
    return 0
  fi
  cat > /etc/fail2ban/jail.d/local-overrides.conf <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${port_spec}
EOF
  run_cmd systemctl restart fail2ban 2>/dev/null || run_cmd systemctl start fail2ban 2>/dev/null || true
}

phase_base() {
  log_info "Обновление индексов и пакетов..."
  run_cmd apt-get update -y
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] apt-get upgrade -y"
  else
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi
  apt_install curl ca-certificates gnupg lsb-release software-properties-common \
    apt-transport-https debconf-utils unattended-upgrades
  log_ok "Базовое обновление завершено."
}

phase_timezone_ntp() {
  prompt_yn "Настроить часовой пояс и синхронизацию времени (NTP, systemd-timesyncd)?" y || return 0
  local tz
  read_nonempty tz "Часовой пояс (например Europe/Prague или UTC): "
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] timedatectl set-timezone $tz"
    SETUP_TIMEZONE="$tz"
    return 0
  fi
  timedatectl set-timezone "$tz" || die "Неверный пояс. Список: timedatectl list-timezones"
  SETUP_TIMEZONE="$tz"
  run_cmd systemctl stop chrony 2>/dev/null || true
  run_cmd systemctl disable chrony 2>/dev/null || true
  run_cmd timedatectl set-ntp true
  run_cmd systemctl enable --now systemd-timesyncd 2>/dev/null || true
  run_cmd systemctl restart systemd-timesyncd 2>/dev/null || true
  log_ok "Время: $(timedatectl show --property=Timezone --value), NTP: $(timedatectl show --property=NTPSynchronized --value)"
}

phase_essentials() {
  log_info "Базовые утилиты и needrestart..."
  apt_install vim-tiny nano htop nload jq git tmux rsync bind9-dnsutils needrestart
  log_ok "Установлены: vim-tiny, nano, htop, nload, jq, git, tmux, rsync, bind9-dnsutils, needrestart."
}

phase_sysctl_tune() {
  prompt_yn "Применить sysctl (rp_filter, ICMP, syncookies + BBR при поддержке ядра)?" y || return 0
  local f=/etc/sysctl.d/99-vps-network-tuning.conf
  if [[ -f "$f" ]] && grep -q '^# managed-by-vps-setup' "$f" 2>/dev/null; then
    prompt_yn "Файл $f уже создан этим скриптом, перезаписать?" n || return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] записать $f"
    return 0
  fi
  cat > "$f" <<'EOF'
# managed-by-vps-setup
# Базовая сеть (дубликаты с дефолтом Ubuntu безвредны)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
EOF
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && \
     grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    cat >> "$f" <<'EOF'
# BBR (если модуль доступен)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    log_ok "В sysctl добавлен BBR + fq."
  else
    log_warn "Модуль BBR недоступен в этом ядре — только базовые параметры."
  fi
  sysctl -p "$f"
  log_ok "Sysctl: $f"
}

phase_fstrim() {
  prompt_yn "Включить еженедельный fstrim.timer (SSD)?" y || return 0
  run_cmd systemctl enable fstrim.timer
  run_cmd systemctl start fstrim.timer
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_ok "fstrim.timer: (dry-run)"
  else
    log_ok "fstrim.timer: $(systemctl is-active fstrim.timer)"
  fi
}

phase_python() {
  log_info "Установка Python 3..."
  apt_install python3 python3-pip python3-venv
  if [[ "${DRY_RUN}" == "0" ]]; then
    log_ok "Python: $(python3 --version 2>&1)"
  else
    log_ok "Python: (dry-run)"
  fi
}

phase_swap() {
  prompt_yn "Настроить swap?" y || return 0
  if swapon --show 2>/dev/null | grep -q '/swapfile'; then
    prompt_yn "Обнаружен активный /swapfile, пропустить настройку swap?" y && return 0
  fi
  local size_gb
  read_nonempty size_gb "Размер swap в ГиБ (например 2): "
  [[ "$size_gb" =~ ^[0-9]+$ ]] || die "Укажите целое число ГиБ (например 2)."
  local swapfile="/swapfile"
  if [[ -f "$swapfile" ]]; then
    log_warn "Файл $swapfile уже существует."
    prompt_yn "Пересоздать swap (отключить, удалить, создать заново)?" n || return 0
    run_cmd swapoff "$swapfile" 2>/dev/null || true
    if [[ "${DRY_RUN}" == "0" ]]; then
      sed -i '\|'"$swapfile"'|d' /etc/fstab
      rm -f "$swapfile"
    fi
  fi
  log_info "Создание $swapfile (${size_gb}G)..."
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] fallocate/dd, mkswap, swapon"
    return 0
  fi
  fallocate -l "${size_gb}G" "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count=$(( size_gb * 1024 )) status=progress
  chmod 600 "$swapfile"
  mkswap "$swapfile"
  swapon "$swapfile"
  grep -q "$swapfile" /etc/fstab || echo "$swapfile none swap sw 0 0" >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
  log_ok "Swap активен: $(swapon --show)"
}

phase_sudo_user() {
  prompt_yn "Создать нового пользователя с sudo?" y || return 0
  local user pass
  read_nonempty user "Имя пользователя: "
  if id "$user" &>/dev/null; then
    prompt_yn "Пользователь $user уже существует, пропустить создание?" y || die "Остановка."
    return 0
  fi
  read_secret_twice pass "Пароль для $user: "
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] adduser + chpasswd + usermod sudo $user"
    return 0
  fi
  adduser --disabled-password --gecos "" "$user"
  echo "$user:$pass" | chpasswd
  usermod -aG sudo "$user"
  log_ok "Пользователь $user добавлен в группу sudo."
}

phase_web() {
  echo "Выберите веб-сервер:"
  echo "  1) Nginx"
  echo "  2) Apache"
  local c
  read -r -p "Ваш выбор [1-2]: " c || true
  case "${c:-1}" in
    2)
      apt_install apache2
      run_cmd systemctl enable --now apache2
      WEB_STACK="apache"
      log_ok "Apache установлен."
      ;;
    *)
      apt_install nginx
      run_cmd systemctl enable --now nginx
      WEB_STACK="nginx"
      log_ok "Nginx установлен."
      ;;
  esac
}

phase_db() {
  echo "Выберите СУБД:"
  echo "  1) MariaDB"
  echo "  2) MySQL (mysql-server из репозитория Ubuntu)"
  local c rootpw
  read -r -p "Ваш выбор [1-2]: " c || true
  read_secret_twice rootpw "Пароль для root СУБД: "
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] установка СУБД (${c:-1}), настройка root"
    DB_KIND=$([[ "${c:-1}" == "2" ]] && echo mysql || echo mariadb)
    return 0
  fi
  case "${c:-1}" in
    2)
      debconf-set-selections <<< "mysql-server mysql-server/root_password password $rootpw"
      debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $rootpw"
      apt_install mysql-server
      run_cmd systemctl enable --now mysql
      mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${rootpw}'; FLUSH PRIVILEGES;" 2>/dev/null || \
        mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${rootpw}'; FLUSH PRIVILEGES;" || true
      mysql -uroot -p"$rootpw" -e "DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null || true
      DB_KIND="mysql"
      ;;
    *)
      apt_install mariadb-server
      run_cmd systemctl enable --now mariadb
      mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${rootpw}'; FLUSH PRIVILEGES;" \
        || mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${rootpw}'; FLUSH PRIVILEGES;"
      mysql -uroot -p"$rootpw" -e "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null || true
      DB_KIND="mariadb"
      ;;
  esac
  log_ok "База данных ($DB_KIND) установлена. Запомните пароль root БД."
}

phase_certbot() {
  prompt_yn "Установить Certbot (Let's Encrypt) под текущий веб-сервер?" y || return 0
  case "${WEB_STACK:-nginx}" in
    apache)
      apt_install certbot python3-certbot-apache
      log_ok "Certbot + Apache. Пример: certbot --apache -d example.com"
      ;;
    *)
      apt_install certbot python3-certbot-nginx
      log_ok "Certbot + Nginx. Пример: certbot --nginx -d example.com"
      ;;
  esac
}

phase_ssh_port() {
  SSH_DUAL_LISTEN=0
  prompt_yn "Сменить порт SSH (меньше шума брутфорса; по умолчанию оставить 22)?" n || return 0
  local p
  read_nonempty p "Новый порт SSH (1024–65535): "
  [[ "$p" =~ ^[0-9]+$ ]] || die "Порт должен быть числом."
  (( p >= 1024 && p <= 65535 )) || die "Порт вне допустимого диапазона."
  SSH_PORT="$p"
  SSH_DUAL_LISTEN=1
  install -d /etc/ssh/sshd_config.d
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] sshd: Port 22 + Port $SSH_PORT (переходный режим), reload"
    log_warn "[DRY-RUN] На реальном запуске: откройте в панели провайдера TCP 22 и $SSH_PORT."
    return 0
  fi
  cat > /etc/ssh/sshd_config.d/98-port.conf <<EOF
# Переходный режим: 22 + новый порт до ручного OK (финализация в конце скрипта)
Port 22
Port ${SSH_PORT}
EOF
  sshd -t || die "Ошибка конфигурации sshd."
  run_cmd systemctl reload ssh 2>/dev/null || run_cmd systemctl reload sshd
  log_warn "Слушаются порты 22 и ${SSH_PORT}. Откройте ОБА в firewall провайдера (Hetzner/AWS/OVH и т.д.), если он есть."
  log_warn "В НОВОМ окне проверьте: ssh -p ${SSH_PORT} user@$(hostname -I | awk '{print $1}')"
  log_ok "После проверки входа скрипт в конце попросит ввести OK — только тогда 22 закроется в UFW/firewalld."
}

phase_firewall() {
  echo "Firewall:"
  echo "  1) UFW (рекомендуется для Ubuntu)"
  echo "  2) firewalld"
  local c
  read -r -p "Ваш выбор [1-2]: " c || true
  case "${c:-1}" in
    2)
      apt_install firewalld
      run_cmd systemctl enable --now firewalld
      if [[ "${SSH_DUAL_LISTEN:-0}" == "1" ]]; then
        run_cmd firewall-cmd --permanent --add-service=ssh
        run_cmd firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
      elif [[ "${SSH_PORT:-22}" == "22" ]]; then
        run_cmd firewall-cmd --permanent --add-service=ssh
      else
        run_cmd firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
      fi
      run_cmd firewall-cmd --permanent --add-service=http
      run_cmd firewall-cmd --permanent --add-service=https
      run_cmd firewall-cmd --reload
      FW_KIND="firewalld"
      UFW_IPV6_POLICY="n/a"
      log_warn "IPv6 в firewalld: проверьте при необходимости: firewall-cmd --permanent --add-service=… и ipv6tables."
      log_ok "firewalld включён (SSH: $([[ "${SSH_DUAL_LISTEN:-0}" == 1 ]] && echo "22+${SSH_PORT}" || echo "${SSH_PORT:-22}"), http, https)."
      ;;
    *)
      apt_install ufw
      UFW_IPV6_POLICY="both"
      echo "IPv6 в UFW:"
      echo "  1) Как в Ubuntu по умолчанию — правила для IPv4 и IPv6"
      echo "  2) Только IPv4 — отключить IPv6 в UFW (IPV6=no в /etc/default/ufw)"
      local u6
      read -r -p "Ваш выбор [1-2]: " u6 || true
      if [[ "${u6:-1}" == "2" ]]; then
        UFW_IPV6_POLICY="ipv4_only"
        if [[ "${DRY_RUN}" == "1" ]]; then
          log_info "[DRY-RUN] /etc/default/ufw: IPV6=no"
        else
          sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
          grep -q '^IPV6=' /etc/default/ufw || echo 'IPV6=no' >> /etc/default/ufw
        fi
        log_ok "UFW: для стека используется только IPv4 (IPv6 в ufw отключён)."
      else
        log_ok "UFW: IPv4 и IPv6 (как в дефолте Ubuntu)."
      fi
      run_cmd ufw default deny incoming
      run_cmd ufw default allow outgoing
      if [[ "${SSH_DUAL_LISTEN:-0}" == "1" ]]; then
        run_cmd ufw allow OpenSSH
        run_cmd ufw allow "${SSH_PORT}/tcp" comment 'ssh target'
      elif [[ "${SSH_PORT:-22}" == "22" ]]; then
        run_cmd ufw allow OpenSSH
      else
        run_cmd ufw allow "${SSH_PORT}/tcp" comment 'ssh'
      fi
      run_cmd ufw allow 80/tcp
      run_cmd ufw allow 443/tcp
      run_cmd ufw --force enable
      FW_KIND="ufw"
      log_ok "UFW включён (SSH: $([[ "${SSH_DUAL_LISTEN:-0}" == 1 ]] && echo "22+${SSH_PORT}" || echo "${SSH_PORT:-22}"))."
      ;;
  esac
}

open_fw_port() {
  local port="$1" proto="${2:-tcp}"
  case "${FW_KIND:-ufw}" in
    firewalld)
      run_cmd firewall-cmd --permanent --add-port="${port}/${proto}" 2>/dev/null && run_cmd firewall-cmd --reload || true
      ;;
    *)
      run_cmd ufw allow "${port}/${proto}" 2>/dev/null || true
      ;;
  esac
}

ensure_docker() {
  if [[ "${DRY_RUN}" == "0" ]] && command -v docker &>/dev/null && docker info &>/dev/null; then
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] ensure_docker (установка при необходимости)"
    return 0
  fi
  log_info "Установка Docker CE..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
  fi
  apt-get update -y
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_cmd systemctl enable --now docker
  log_ok "Docker готов."
}

phase_fail2ban() {
  log_info "Установка Fail2Ban..."
  apt_install fail2ban
  local f2b_port
  if [[ "${SSH_DUAL_LISTEN:-0}" == "1" ]]; then
    f2b_port="22,${SSH_PORT}"
  else
    f2b_port="${SSH_PORT:-22}"
  fi
  run_cmd systemctl enable --now fail2ban
  fail2ban_write_jail "$f2b_port"
  log_ok "Fail2Ban активен (sshd порт(ы): ${f2b_port})."
}

phase_cockpit() {
  prompt_yn "Установить Cockpit (веб-панель, порт 9090)?" y || return 0
  apt_install cockpit
  run_cmd systemctl enable --now cockpit.socket
  open_fw_port 9090
  log_ok "Cockpit: https://$(hostname -I | awk '{print $1}'):9090"
}

phase_webmin() {
  prompt_yn "Установить Webmin (порт 10000)?" n || return 0
  install -d /usr/share/keyrings
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] webmin repo + install"
    open_fw_port 10000
    return 0
  fi
  curl -fsSL https://download.webmin.com/jcameron-key.asc | gpg --dearmor -o /usr/share/keyrings/webmin-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/webmin-archive-keyring.gpg] https://download.webmin.com/download/repository sarge contrib" \
    > /etc/apt/sources.list.d/webmin.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y webmin
  open_fw_port 10000
  log_ok "Webmin: https://$(hostname -I | awk '{print $1}'):10000"
}

phase_docker_portainer() {
  prompt_yn "Установить Docker и Portainer CE (порты 8000, 9443)?" n || return 0
  ensure_docker
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] docker run portainer"
    open_fw_port 8000
    open_fw_port 9443
    return 0
  fi
  docker volume create portainer_data >/dev/null 2>&1 || true
  docker rm -f portainer 2>/dev/null || true
  docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
  open_fw_port 8000
  open_fw_port 9443
  log_ok "Portainer: https://$(hostname -I | awk '{print $1}'):9443"
}

phase_netdata() {
  prompt_yn "Установить Netdata (мониторинг, порт 19999)?" n || return 0
  echo "Способ установки Netdata:"
  echo "  1) Нативно (скрипт kickstart с netdata.cloud — агент в системе)"
  echo "  2) Docker (контейнер netdata/netdata)"
  local c
  read -r -p "Ваш выбор [1-2]: " c || true
  case "${c:-1}" in
    2)
      ensure_docker
      if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] netdata docker"
        open_fw_port 19999
        return 0
      fi
      run_cmd systemctl stop netdata 2>/dev/null || true
      run_cmd systemctl disable netdata 2>/dev/null || true
      docker pull netdata/netdata:latest
      docker rm -f netdata 2>/dev/null || true
      docker run -d --name=netdata \
        -p 19999:19999 \
        -v netdataconfig:/etc/netdata \
        -v netdatalib:/var/lib/netdata \
        -v netdatacache:/var/cache/netdata \
        -v /etc/passwd:/host/etc/passwd:ro \
        -v /etc/group:/host/etc/group:ro \
        -v /proc:/host/proc:ro \
        -v /sys:/host/sys:ro \
        -v /etc/os-release:/host/etc/os-release:ro \
        --hostname="$(hostname)" \
        --restart=always \
        --cap-add SYS_PTRACE \
        --cap-add SYS_ADMIN \
        --security-opt apparmor=unconfined \
        netdata/netdata:latest
      open_fw_port 19999
      log_ok "Netdata (Docker): http://$(hostname -I | awk '{print $1}'):19999"
      ;;
    *)
      if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] netdata kickstart"
        open_fw_port 19999
        return 0
      fi
      docker rm -f netdata 2>/dev/null || true
      bash <(curl -fsSL https://get.netdata.cloud/kickstart.sh) --non-interactive --disable-telemetry || {
        log_warn "Kickstart Netdata завершился с ошибкой; проверьте логи выше."
        return 0
      }
      open_fw_port 19999
      log_ok "Netdata (нативно): http://$(hostname -I | awk '{print $1}'):19999"
      ;;
  esac
}

phase_logwatch() {
  prompt_yn "Настроить logwatch (ежедневные отчёты по почте)?" n || return 0
  apt_install logwatch
  local email
  read_nonempty email "Email для отчётов logwatch: "
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] logwatch cron $email"
    return 0
  fi
  sed -i "s|^MAILTO=.*|MAILTO=$email|" /etc/cron.daily/00logwatch 2>/dev/null || true
  if ! grep -q '^MAILTO=' /etc/cron.daily/00logwatch 2>/dev/null; then
    echo "/usr/sbin/logwatch --output mail --mailto $email --detail high" > /etc/cron.daily/00logwatch
    chmod +x /etc/cron.daily/00logwatch
  fi
  log_ok "Logwatch: ежедневно на $email (нужен работающий MTA/SMTP на сервере или relay)."
}

phase_ssh_port_finalize() {
  [[ "${SSH_DUAL_LISTEN:-0}" != "1" ]] && return 0
  echo ""
  log_warn "Финализация SSH: после подтверждения останется только порт ${SSH_PORT}."
  log_warn "Убедитесь, что вход работает: ssh -p ${SSH_PORT} ... (и что порт открыт у провайдера)."
  echo "Введите OK (заглавными), если всё проверили; любой другой ввод — оставить 22 и ${SSH_PORT} до ручной правки."
  local line
  read -r -p "> " line || true
  if [[ "${line}" != "OK" ]]; then
    log_warn "Финализация отложена: sshd слушает 22 и ${SSH_PORT}; правило для 22 в firewall сохранено."
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] только порт ${SSH_PORT}, удалить 22 из firewall, fail2ban port=${SSH_PORT}"
    SSH_DUAL_LISTEN=0
    return 0
  fi
  printf '# Финализировано скриптом vps-setup\nPort %s\n' "${SSH_PORT}" > /etc/ssh/sshd_config.d/98-port.conf
  sshd -t || die "sshd -t после финализации."
  run_cmd systemctl reload ssh 2>/dev/null || run_cmd systemctl reload sshd
  if [[ "${FW_KIND}" == "ufw" ]]; then
    run_cmd ufw delete allow OpenSSH 2>/dev/null || true
    run_cmd ufw delete allow 22/tcp 2>/dev/null || true
    run_cmd ufw status verbose || true
  elif [[ "${FW_KIND}" == "firewalld" ]]; then
    run_cmd firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
    run_cmd firewall-cmd --reload 2>/dev/null || true
  fi
  fail2ban_write_jail "${SSH_PORT}"
  SSH_DUAL_LISTEN=0
  log_ok "SSH только на порту ${SSH_PORT}; доступ по 22 в хостовом firewall снят (проверьте внешний firewall провайдера)."
}

phase_monit() {
  prompt_yn "Установить Monit (контроль сервисов)?" y || return 0
  apt_install monit
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] monit vps-services.conf ssh port ${SSH_PORT:-22}"
    return 0
  fi
  cat > /etc/monit/conf.d/vps-services.conf <<MONIT
check process sshd with matching "sshd"
  start program = "/bin/systemctl start ssh"
  stop  program = "/bin/systemctl stop ssh"
  if failed port ${SSH_PORT:-22} protocol ssh for 2 cycles then restart

check process cron with matching "cron"
  start program = "/bin/systemctl start cron"
  stop  program = "/bin/systemctl stop cron"
MONIT
  if [[ "${WEB_STACK:-}" == "nginx" ]]; then
    cat >> /etc/monit/conf.d/vps-services.conf <<'MONIT'
check process nginx with pidfile /run/nginx.pid
  start program = "/bin/systemctl start nginx"
  stop  program = "/bin/systemctl stop nginx"
MONIT
  elif [[ "${WEB_STACK:-}" == "apache" ]]; then
    cat >> /etc/monit/conf.d/vps-services.conf <<'MONIT'
check process apache with pidfile /run/apache2/apache2.pid
  start program = "/bin/systemctl start apache2"
  stop  program = "/bin/systemctl stop apache2"
MONIT
  fi
  run_cmd systemctl enable --now monit
  monit reload 2>/dev/null || true
  log_ok "Monit: веб-интерфейс по умолчанию на 127.0.0.1:2812 (см. /etc/monit/monitrc)."
}

phase_auditd() {
  prompt_yn "Установить auditd?" y || return 0
  apt_install auditd audispd-plugins
  run_cmd systemctl enable --now auditd
  log_ok "auditd активен."
}

phase_ssh_harden() {
  log_info "Усиление SSH..."
  install -d /etc/ssh/sshd_config.d
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] 99-vps-hardening.conf + reload sshd"
    return 0
  fi
  cat > /etc/ssh/sshd_config.d/99-vps-hardening.conf <<'EOF'
# Доп. настройки (основной sshd_config не перезаписывается)
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  if prompt_yn "Полностью запретить вход root по SSH (только ключи sudo-пользователя)?" n; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config.d/99-vps-hardening.conf
  fi
  if prompt_yn "Разрешить TCP forwarding (нужно для некоторых туннелей)?" n; then
    sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config.d/99-vps-hardening.conf
  fi
  sshd -t || die "Проверка sshd не прошла (sshd -t)."
  run_cmd systemctl reload ssh 2>/dev/null || run_cmd systemctl reload sshd
  log_ok "SSH перезагружен с новыми параметрами."
}

phase_unattended() {
  log_info "Включение автоматических обновлений безопасности..."
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] 20auto-upgrades + unattended-upgrades"
    return 0
  fi
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  run_cmd systemctl enable unattended-upgrades
  run_cmd systemctl restart unattended-upgrades
  log_ok "unattended-upgrades включён (проверьте /etc/apt/apt.conf.d/50unattended-upgrades при необходимости)."
}

write_setup_summary() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY-RUN] сводка не пишется в ${SUMMARY_FILE}"
    return 0
  fi
  local tz="${SETUP_TIMEZONE:-}"
  [[ -z "$tz" ]] && tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "?")
  (
    umask 077
    # shellcheck source=/dev/null
    . /etc/os-release
    {
      echo "vps-setup-ubuntu24.sh ${SCRIPT_VERSION}"
      echo "generated: $(date -Is)"
      echo "hostname: $(hostname)"
      echo "ubuntu: ${PRETTY_NAME:-$VERSION_ID}"
      echo "timezone: ${tz}"
      echo "ssh_port: ${SSH_PORT:-22}"
      echo "ssh_dual_listen_active: ${SSH_DUAL_LISTEN:-0}  # 1 = ещё слушаются 22 и новый порт (финализация не выполнена или отклонена)"
      echo "web_server: ${WEB_STACK:-}"
      echo "database: ${DB_KIND:-}"
      echo "firewall: ${FW_KIND:-}"
      echo "ufw_ipv6: ${UFW_IPV6_POLICY:-n/a}  # both | ipv4_only | n/a (не UFW)"
      echo "install_log: ${LOG_FILE}"
    } > "${SUMMARY_FILE}"
  )
  chmod 600 "${SUMMARY_FILE}"
  log_ok "Сводка (chmod 600): ${SUMMARY_FILE}"
}

main() {
  require_root
  maybe_reexec_tmux
  setup_logging

  echo ""
  echo "=========================================="
  echo " Universal VPS Setup — Ubuntu 24.04 LTS v${SCRIPT_VERSION}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo " РЕЖИМ --dry-run (изменения в системе не применяются)"
  fi
  echo " Лог: ${LOG_FILE}"
  echo "=========================================="
  echo ""

  check_ubuntu_release
  [[ "${DRY_RUN}" == "1" ]] && log_warn "Dry-run: пакеты и сервисы не меняются; ответы на вопросы сохраняются только в лог."

  WEB_STACK=""
  DB_KIND=""
  FW_KIND="ufw"
  UFW_IPV6_POLICY="n/a"
  SSH_PORT=22
  SSH_DUAL_LISTEN=0
  SETUP_TIMEZONE=""

  phase_base
  phase_timezone_ntp
  phase_essentials
  phase_sysctl_tune
  phase_fstrim
  phase_python
  phase_swap
  phase_sudo_user
  phase_web
  phase_db
  phase_certbot
  phase_ssh_port
  phase_firewall
  phase_fail2ban
  phase_cockpit
  phase_webmin
  phase_docker_portainer
  phase_netdata
  phase_logwatch
  phase_ssh_port_finalize
  phase_monit
  phase_auditd
  phase_ssh_harden
  phase_unattended

  write_setup_summary

  echo ""
  log_ok "Настройка завершена. Проверьте открытые порты и доступ к панелям."
  log_warn "Сохраните пароли БД и пользователя; ограничьте доступ к панелям при необходимости (VPN / allowlist)."
  if [[ "${SSH_DUAL_LISTEN:-0}" == "1" ]]; then
    log_warn "SSH всё ещё на 22 и ${SSH_PORT}: при готовности отредактируйте /etc/ssh/sshd_config.d/98-port.conf и firewall вручную или перезапустите скрипт до шага финализации."
  fi
  echo ""
}

main "$@"
