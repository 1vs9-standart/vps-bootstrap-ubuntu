# VPS bootstrap (Ubuntu 24.04)

Интерактивная первичная настройка сервера (`vps-bootstrap-ubuntu.sh`).

## Что внутри

- Обновление пакетов (apt)
- Часовой пояс и синхронизация времени (NTP)
- Базовые утилиты и **needrestart**
- **sysctl** (сеть, **BBR** при поддержке ядра), **fstrim**
- **Python 3**
- **Swap** (размер по запросу)
- Новый пользователь с **sudo**
- **Nginx** или **Apache**
- **MariaDB** или **MySQL**
- **Certbot** (Let’s Encrypt)
- **SSH**: опциональная смена порта в два шага (22 остаётся в firewall до подтверждения **OK**)
- **UFW** или **firewalld**
- **Fail2Ban**
- По желанию: **Cockpit**, **Webmin**, **Docker** + **Portainer**, **Netdata** (нативно или в Docker), **Logwatch**, **Monit**, **auditd**
- Усиление **SSH**, автоматические обновления безопасности (**unattended-upgrades**)
- Режим **`--dry-run`**, лог и краткая сводка на диске

## Файлы после работы

| Что | Где |
|-----|-----|
| Лог | `/var/log/vps-setup-ubuntu24.log` |
| Сводка | `/root/.vps-setup-summary` |
