#!/bin/bash

echo "=== Проверка установки 1С сервера ==="
echo

echo "1. Проверка службы 1С..."
SERVICE_NAME=$(systemctl list-units --all | grep srv1cv8 | head -1 | awk '{print $1}')
if [ -n "$SERVICE_NAME" ]; then
    echo "   Найдена служба: $SERVICE_NAME"
    sudo systemctl status $SERVICE_NAME --no-pager | grep -E "(Active:|Loaded:|Main PID:)"
else
    echo "   Служба 1С не найдена!"
fi

echo
echo "2. Проверка установленных пакетов..."
dpkg -l | grep -i "1c-enterprise" | awk '{print "   " $2 " - " $3}'


echo
echo "3. Проверка версий в /opt/1cv8..."
if [ -d "/opt/1cv8/x86_64" ]; then
    INSTALLED_VERSIONS=$(ls /opt/1cv8/x86_64/)
    echo "   Установленные версии:"
    for ver in $INSTALLED_VERSIONS; do
        echo "   - $ver"
    done
else
    echo "   Директория /opt/1cv8/x86_64 не найдена!"
fi

echo
echo "4. Проверка логов установки..."
if [ -f "/var/log/1c_install.log" ]; then
    LAST_ERROR=$(tail -20 /var/log/1c_install.log | grep -i "error\|fail\|ошибка\|сбой")
    if [ -n "$LAST_ERROR" ]; then
        echo "   Найдены ошибки в логе:"
        echo "   $LAST_ERROR"
    else
        echo "   В логе ошибок не обнаружено"
    fi
else
    echo "   Файл лога не найден: /var/log/1c_install.log"
fi

echo
echo "=== Проверка завершена ==="
echo "=== Проверка завершена ==="
