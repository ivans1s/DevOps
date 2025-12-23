#!/bin/bash
set -e

# === Настройки ===
DOWNLOAD_URL="https://f1.atoldriver.ru/1c/latest.zip"
WORKDIR="/opt/install-1c"
LOGFILE="/var/log/1c_install.log"
ARCHIVE_STORAGE="/opt/1c-archives"
PACKAGE_STORAGE="/opt/1c-packages"

# === Логирование ===
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

# === Парсинг аргументов ===
TIMEZONE_PARAM=""
KEEP_ARCHIVE=false
FORCE_SETUP=false
for arg in "$@"; do
    case $arg in
        --timezone=*)
            TIMEZONE_PARAM="${arg#*=}"
            ;;
        --keep-archive)
            KEEP_ARCHIVE=true
            ;;
        --force-setup)
            FORCE_SETUP=true
            ;;
        -h|--help)
            echo "Использование: $0 [--timezone=<zone>] [--keep-archive] [--force-setup]"
            echo "  --timezone=<zone>    Установка часового пояса (пример: Asia/Irkutsk)"
            echo "  --keep-archive       Сохранить скачанный архив и пакеты"
            echo "  --force-setup        Принудительно выполнить настройку системы"
            echo "  -h, --help          Показать эту справку"
            exit 0
            ;;
    esac
done

echo "Запуск установки/обновления 1С сервера"
echo "Лог: $LOGFILE"
echo "Хранилище архивов: $ARCHIVE_STORAGE"
echo "Хранилище пакетов: $PACKAGE_STORAGE"
echo

# === Создание папок для хранения ===
echo "Создаю папки для хранения..."
sudo mkdir -p "$ARCHIVE_STORAGE" "$PACKAGE_STORAGE"
sudo chown -R $USER:$USER "$ARCHIVE_STORAGE" "$PACKAGE_STORAGE"

# === Проверяем, установлена ли 1С ===
IS_FIRST_INSTALL=false
if [ -d /opt/1cv8/x86_64 ]; then
    CURRENT_VERSION=$(ls /opt/1cv8/x86_64 | sort -V | tail -n1)
    echo "Текущая установленная версия: $CURRENT_VERSION"
    IS_FIRST_INSTALL=false
else
    CURRENT_VERSION="0.0.0.0"
    echo "1С не установлена, будет выполнена чистая установка."
    IS_FIRST_INSTALL=true
fi

# === Настройка системы только при первой установке или принудительно ===
if [ "$IS_FIRST_INSTALL" = true ] || [ "$FORCE_SETUP" = true ]; then
    echo "Выполняю первоначальную настройку системы..."
    
    echo "Обновление списка пакетов..."
    sudo apt-get update
    echo "Обновление установленных пакетов..."
    sudo apt-get upgrade -y

    echo "Установка локалей..."
    sudo apt-get install -y locales
    sudo locale-gen en_US.UTF-8 ru_RU.UTF-8
    sudo update-locale LANG=ru_RU.UTF-8

    echo "Настройка часового пояса..."
    CURRENT_TZ=$(timedatectl show -p Timezone --value)

    if [ -n "$TIMEZONE_PARAM" ]; then
        NEW_TZ="$TIMEZONE_PARAM"
        echo "Используется часовой пояс из параметра: $NEW_TZ"
    else
        echo "Текущий часовой пояс: $CURRENT_TZ"
        echo
        echo "Выберите новый часовой пояс или оставьте текущий:"
        PS3="Введите номер варианта: "
        options=(
            "Оставить текущий ($CURRENT_TZ)"
            "Europe/Moscow"
            "Asia/Yekaterinburg"
            "Asia/Novosibirsk"
            "Asia/Irkutsk"
            "Asia/Vladivostok"
            "Asia/Krasnoyarsk"
            "Указать вручную"
        )
        select opt in "${options[@]}"; do
            case $REPLY in
                1)
                    NEW_TZ="$CURRENT_TZ"; break;;
                2|3|4|5|6|7)
                    NEW_TZ="$opt"; break;;
                8)
                    read -rp "Введите свой часовой пояс (например, Europe/Samara): " NEW_TZ; break;;
                *)
                    echo "Неверный выбор, попробуйте снова.";;
            esac
        done
    fi

    echo "Устанавливаю часовой пояс: $NEW_TZ"
    sudo timedatectl set-timezone "$NEW_TZ"
    echo "Часовой пояс установлен: $(timedatectl show -p Timezone --value)"
    echo

    echo msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections

    echo "Установка зависимостей..."
    sudo apt-get install -y ttf-mscorefonts-installer imagemagick unixodbc libgsf-bin t1utils unzip wget

else
    echo "Пропускаю настройку системы (уже установлена 1С)"
    echo "Для принудительной настройки используйте --force-setup"
fi

# === Работаем в рабочей директории ===
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# === Скачиваем последнюю версию ===
echo "Скачиваю последнюю версию 1С..."
ARCHIVE_NAME="1c_server_$(date +%Y%m%d_%H%M%S).zip"
ARCHIVE_PATH="$ARCHIVE_STORAGE/$ARCHIVE_NAME"

if wget --help | grep -q "show-progress"; then
    echo "Скачивание архива (с прогресс-баром)..."
    wget --show-progress -O "$ARCHIVE_PATH" "$DOWNLOAD_URL"
else
    echo "Скачивание архива..."
    wget -O "$ARCHIVE_PATH" "$DOWNLOAD_URL"
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "Ошибка: архив не скачался или не сохранился в $ARCHIVE_PATH"
    exit 1
fi

echo "Архив успешно скачан: $ARCHIVE_PATH"
echo "Размер архива: $(du -h "$ARCHIVE_PATH" | cut -f1)"

# === Анализ содержимого архива ===
echo "Анализ содержимого архива..."

TEMP_ANALYSIS="$WORKDIR/analysis_$$"
mkdir -p "$TEMP_ANALYSIS"

unzip -q -l "$ARCHIVE_PATH" > "$TEMP_ANALYSIS/archive_contents.txt"

echo "Содержимое архива:"
cat "$TEMP_ANALYSIS/archive_contents.txt"

DEB_FILES=$(grep -E "\.deb$" "$TEMP_ANALYSIS/archive_contents.txt" | awk '{print $4}' | grep -v "^$")

if [ -z "$DEB_FILES" ]; then
    echo "Не удалось найти DEB пакеты через анализ списка, пробую альтернативный метод..."
    unzip -q "$ARCHIVE_PATH" -d "$TEMP_ANALYSIS/extracted"
    DEB_FILES=$(find "$TEMP_ANALYSIS/extracted" -name "*.deb" -type f | head -5)
    
    if [ -z "$DEB_FILES" ]; then
        echo "Не удалось найти DEB пакеты в архиве после распаковки"
        echo "Содержимое распакованной папки:"
        ls -la "$TEMP_ANALYSIS/extracted"
        rm -rf "$TEMP_ANALYSIS"
        exit 1
    else
        echo "Найдены DEB пакеты через распаковку:"
        echo "$DEB_FILES" | while read line; do
            echo "   - $(basename "$line")"
        done
    fi
else
    echo "Найдены DEB пакеты в архиве:"
    echo "$DEB_FILES" | while read line; do
        echo "   - $line"
    done
fi

FIRST_DEB=$(echo "$DEB_FILES" | head -1)
DEB_FILENAME=$(basename "$FIRST_DEB")

echo "Извлекаю версию из файла: $DEB_FILENAME"

NEW_VERSION=$(echo "$DEB_FILENAME" | grep -oE '[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+' | head -1)

if [ -z "$NEW_VERSION" ]; then
    NEW_VERSION=$(echo "$DEB_FILENAME" | sed -E 's/.*([0-9]+[.][0-9]+[.][0-9]+[.][0-9]+).*/\1/' | head -1)
fi

if [ -z "$NEW_VERSION" ]; then
    NEW_VERSION=$(echo "$DEB_FILENAME" | sed -E 's/.*([0-9]+[.][0-9]+[.][0-9]+)-([0-9]+).*/\1.\2/' | head -1)
fi

if [ -z "$NEW_VERSION" ]; then
    echo "Не удалось определить версию из файла: $DEB_FILENAME"
    echo "Все найденные файлы:"
    echo "$DEB_FILES"
    rm -rf "$TEMP_ANALYSIS"
    exit 1
fi

echo "Найдена версия для установки: $NEW_VERSION"

rm -rf "$TEMP_ANALYSIS"

# === Упрощенное сравнение версий ===
echo "Сравниваю версии:"
echo "   Текущая: $CURRENT_VERSION"
echo "   Новая:   $NEW_VERSION"

if [ "$IS_FIRST_INSTALL" = true ]; then
    echo "Первая установка, продолжаю..."
else
    HIGHER_VERSION=$(echo -e "$CURRENT_VERSION\n$NEW_VERSION" | sort -V | tail -n1)
    
    if [ "$HIGHER_VERSION" = "$CURRENT_VERSION" ]; then
        echo "Установлена более новая или такая же версия ($CURRENT_VERSION). Обновление не требуется."
        if [ "$KEEP_ARCHIVE" = false ]; then
            rm -f "$ARCHIVE_PATH"
        fi
        exit 0
    else
        echo "Будет установлена новая версия: $NEW_VERSION (старше чем $CURRENT_VERSION)"
    fi
fi

# === Распаковываем архив для установки ===
echo "Распаковка архива для установки..."
TEMP_EXTRACT="$WORKDIR/extract_$$"
mkdir -p "$TEMP_EXTRACT"
unzip -q -o "$ARCHIVE_PATH" -d "$TEMP_EXTRACT"

# === Сохраняем пакеты в постоянное хранилище ===
PACKAGE_VERSION_DIR="$PACKAGE_STORAGE/$NEW_VERSION"
mkdir -p "$PACKAGE_VERSION_DIR"

echo "Сохраняю пакеты в: $PACKAGE_VERSION_DIR"
cp -r "$TEMP_EXTRACT"/* "$PACKAGE_VERSION_DIR/" 2>/dev/null || true

cd "$TEMP_EXTRACT"

# === Проверяем наличие DEB пакетов ===
DEB_PACKAGES=$(find . -name "*.deb" -type f)

if [ -z "$DEB_PACKAGES" ]; then
    echo "Не найдены DEB пакеты после распаковки"
    echo "Содержимое папки:"
    ls -la
    exit 1
fi

echo "Найдены пакеты для установки:"
echo "$DEB_PACKAGES" | while read package; do
    echo "   - $(basename "$package")"
done

# === Останавливаем старую службу ===
if [ "$IS_FIRST_INSTALL" = false ] && systemctl list-units --full -all | grep -q "srv1cv8-${CURRENT_VERSION}@default.service"; then
    echo "Останавливаю текущую службу 1С..."
    sudo systemctl stop "srv1cv8-${CURRENT_VERSION}@default.service" || true
    sudo systemctl disable "srv1cv8-${CURRENT_VERSION}@default.service" || true
fi

# === Устанавливаем пакеты в правильном порядке ===
echo "Устанавливаю пакеты 1С версии $NEW_VERSION..."

install_package_by_pattern() {
    local pattern=$1
    local package=$(find . -name "$pattern" -type f | head -1)
    if [ -n "$package" ]; then
        echo "Устанавливаю: $(basename "$package")"
        sudo dpkg -i "$package"
        return 0
    else
        echo "Не найден пакет: $pattern"
        return 1
    fi
}

install_package_by_pattern "1c-enterprise*-common_*_amd64.deb"
install_package_by_pattern "1c-enterprise*-server_*_amd64.deb"
install_package_by_pattern "1c-enterprise*-ws_*_amd64.deb"

OTHER_PACKAGES=$(find . -name "*.deb" -type f ! -name "*common*" ! -name "*server*" ! -name "*ws*")
if [ -n "$OTHER_PACKAGES" ]; then
    echo "Устанавливаю дополнительные пакеты:"
    echo "$OTHER_PACKAGES" | while read package; do
        echo "   - $(basename "$package")"
        sudo dpkg -i "$package"
    done
fi

echo "Исправление зависимостей..."
sudo apt-get install -f -y

# === Настройка службы ===
SERVICE_PATH="/opt/1cv8/x86_64/$NEW_VERSION/srv1cv8-$NEW_VERSION@.service"

if [ -f "$SERVICE_PATH" ]; then
    echo "Настраиваю systemd для новой версии..."
    sudo systemctl link "$SERVICE_PATH"
    sudo systemctl enable "srv1cv8-$NEW_VERSION@default.service"
    sudo systemctl start "srv1cv8-$NEW_VERSION@default.service"
    echo "1С сервер версии $NEW_VERSION успешно установлен и запущен!"
else
    echo "Файл службы не найден: $SERVICE_PATH"
    echo "Попытка найти службу автоматически..."
    FOUND_SERVICE=$(find /opt/1cv8 -name "srv1cv8-$NEW_VERSION@.service" -type f | head -1)
    if [ -n "$FOUND_SERVICE" ]; then
        echo "Найдена служба: $FOUND_SERVICE"
        sudo systemctl link "$FOUND_SERVICE"
        sudo systemctl enable "srv1cv8-$NEW_VERSION@default.service"
        sudo systemctl start "srv1cv8-$NEW_VERSION@default.service"
        echo "1С сервер версии $NEW_VERSION успешно установлен и запущен!"
    else
        echo "Служба не найдена. Проверьте установку вручную."
        echo "Попробуйте найти службу: find /opt -name \"*srv1cv8*\" -type f"
    fi
fi

echo "Проверка статуса службы..."
if systemctl is-active "srv1cv8-$NEW_VERSION@default.service" >/dev/null 2>&1; then
    echo "Служба 1С запущена успешно"
else
    echo "Служба 1С не запущена. Проверьте конфигурацию."
fi

echo "Очистка временных файлов..."
rm -rf "$TEMP_EXTRACT"

if [ "$KEEP_ARCHIVE" = false ]; then
    rm -f "$ARCHIVE_PATH"
    echo "Архив удален, пакеты сохранены в: $PACKAGE_VERSION_DIR"
else
    echo "Архив и пакеты сохранены:"
    echo "   Архив: $ARCHIVE_PATH"
    echo "   Пакеты: $PACKAGE_VERSION_DIR"
fi

echo ""
echo "Информация о хранилищах:"
echo "   Архивы: $ARCHIVE_STORAGE"
echo "   Пакеты: $PACKAGE_STORAGE"
if [ -d "$PACKAGE_STORAGE" ]; then
    echo "   Сохраненные версии пакетов:"
    ls -la "$PACKAGE_STORAGE" | grep -E "^d" | awk '{print "     - " $9}'
fi

echo "Установка завершена успешно!"
