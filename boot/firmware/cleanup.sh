#!/bin/bash

# Удаляем скачанные .deb-файлы
sudo apt clean

# Удаляем неиспользуемые ядра
KREL="$(uname -r)"
ARCH_SUFFIX="${KREL#*+rpt}"
ARCH_NAME="${ARCH_SUFFIX#-}"
COMMON_VER="${KREL%${ARCH_SUFFIX}}"
dpkg -l 'linux-*' | grep '^ii' | grep -vF "$KREL" | awk '{print $2}' | grep -E 'linux-(image|headers|modules)' | grep -vxF -e "linux-image-${ARCH_NAME}" -e "linux-headers-${ARCH_NAME}" -e "linux-headers-${COMMON_VER}-common-rpi" | xargs -r sudo apt purge -y

# Удаляем пакеты, установленные автоматически и ставшие ненужными
sudo apt autoremove --purge -y

# Дополнительная очистка устаревших файлов кэша
sudo apt autoclean

# Останавливаем службы, которые могут писать логи
sudo systemctl stop rsyslog 2>/dev/null || true
sudo systemctl stop systemd-journald.service systemd-journald.socket 2>/dev/null || true

# Полностью удаляем журналы systemd (постоянные и временные)
sudo rm -rf /var/log/journal/* 2>/dev/null
sudo rm -rf /run/log/journal/* 2>/dev/null

# Удаляем сжатые и ротированные логи
sudo find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.[0-9]" -o -name "*.1" \) -delete

# Обнуляем все оставшиеся файлы в /var/log (включая подкаталоги)
sudo find /var/log -type f -exec truncate -s 0 {} \;

# Обнуляем бинарные журналы входов и неудачных попыток
sudo truncate -s 0 /var/log/wtmp /var/log/btmp /var/log/lastlog /var/log/faillog 2>/dev/null

# Временные директории
sudo rm -rf /tmp/*
sudo rm -rf /var/tmp/*

# Кэш текущего пользователя и root
rm -rf ~/.cache/*
sudo rm -rf /root/.cache/*

# Эскизы (thumbnails)
rm -rf ~/.cache/thumbnails/* 2>/dev/null || true

# Проверяем, установлен ли cloud-init
if command -v cloud-init >/dev/null 2>&1; then
    sudo cloud-init clean --logs
    sudo rm -f /var/log/cloud-init*
fi

# История команд Bash
rm -f ~/.bash_history
sudo rm -f /root/.bash_history

# Создаём большой файл из нулей, пока не закончится место (ошибка "No space left" ожидаема)
sudo dd if=/dev/zero of=/tmp/zero.fill bs=1M status=progress || true

# Удаляем созданный файл
sudo rm -f /tmp/zero.fill

# Синхронизируем данные на диск
sync

# Команды Bash в текущей сессии
history -c && history -w

# Выключаем RPi-Zero
 sudo powerof