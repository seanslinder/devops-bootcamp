# Инструкция по развёртыванию стенда DataLens на РЕД ОС

## Предварительные требования

- VMware Workstation (или аналог)
- Образ РЕД ОС
- Минимум 4 ГБ RAM и 2 ядра CPU для VM
- Минимум 40 ГБ дискового пространства
- Сеть: Bridged (чтобы VM была доступна из локальной сети)

---

## Часть 1. Установка и базовая настройка РЕД ОС

### 1.1. Установка ОС

Установите РЕД ОС стандартным способом. При установке создайте обычного пользователя — это избавит от необходимости создавать его потом вручную.

### 1.2. Обновление системы

```bash
sudo dnf update -y
```

---

## Часть 2. Установка Docker и Docker Compose

### 2.1. Установка Docker

```bash
sudo dnf install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
```

### 2.2. Установка Docker Compose

```bash
sudo dnf install -y docker-compose
docker compose version
```

### 2.3. Добавить пользователя в группу docker

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### 2.4. Проверка

```bash
docker ps
docker --version
```

---

## Часть 3. PostgreSQL в Docker

### 3.1. Создать `docker-compose.yml` для PostgreSQL

```yaml
services:
  db:
    image: postgres:16
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: <db-password>
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

### 3.2. Запустить

```bash
docker compose up -d
```

### 3.3. Проверка

```bash
docker compose ps
docker exec -it postgres psql -U postgres
```

---

## Часть 4. DataLens Open Source

### 4.1. Клонирование репозитория

```bash
git clone https://github.com/datalens-tech/datalens
cd datalens
```

### 4.2. Генерация конфигурации

```bash
./init.sh
```

Скрипт сгенерирует `docker-compose.production.yaml` и `.env` с паролями и ключами.

### 4.3. Правка `docker-compose.production.yaml`

В **каждый сервис** добавьте:

```yaml
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

### 4.4. Добавить `HC=1` в `.env`

```bash
echo "HC=1" >> .env
```

### 4.5. Запуск

```bash
docker compose -f docker-compose.production.yaml up -d
```

### 4.6. Проверка

```bash
docker compose -f docker-compose.production.yaml ps
```

Все контейнеры должны быть `Up` или `healthy`.

### 4.7. Пароль администратора

```bash
grep AUTH_ADMIN_PASSWORD .env
```

Логин — `admin`, пароль — из `.env`.

---

## Часть 5. dnsmasq (локальный DNS)

### 5.1. Установка

```bash
sudo dnf install -y dnsmasq
```

### 5.2. Отключить systemd-resolved

```bash
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo systemctl mask systemd-resolved
```

### 5.3. Настройка

```bash
sudo nano /etc/dnsmasq.conf
```

Добавьте:

```
address=/datalens.internal/<vm-ip>
```

`datalens.internal` можно заменить на любое другое имя — например, `datalens.local`, `datalens.lan`, `bi.company`. Главное, чтобы оно не пересекалось с реально существующими доменами.

Уберите или закомментируйте `local-service=host`, если она есть.

### 5.4. `/etc/resolv.conf`

Поставьте `nameserver 127.0.0.1` **первым** среди DNS-серверов в `/etc/resolv.conf`. Это нужно, чтобы сайт открывался по доменному имени и на самой машине РЕД ОС — может пригодиться для тестов.

### 5.5. Запуск

```bash
sudo systemctl enable --now dnsmasq
sudo ss -tulnp | grep :53
```

dnsmasq должен слушать `0.0.0.0:53`.

### 5.6. Проверка

```bash
nslookup datalens.internal
```

---

## Часть 6. nginx + TLS

### 6.1. Установка

```bash
sudo dnf install -y nginx
```

### 6.2. Сертификат

```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/datalens.key \
  -out /etc/nginx/ssl/datalens.crt \
  -subj "/CN=datalens.internal"
```

### 6.3. Конфиг

Создайте `/etc/nginx/conf.d/datalens.conf`:

```nginx
server {
    listen 443 ssl;
    server_name datalens.internal;

    ssl_certificate     /etc/nginx/ssl/datalens.crt;
    ssl_certificate_key /etc/nginx/ssl/datalens.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 80;
    server_name datalens.internal;
    return 301 https://$host$request_uri;
}
```

### 6.4. SELinux

```bash
sudo setsebool -P httpd_can_network_connect 1
```

### 6.5. Запуск

```bash
sudo nginx -t
sudo systemctl enable --now nginx
```

### 6.6. Проверка

```bash
curl -k https://datalens.internal
```

---

## Часть 7. Доступ с других ПК

На каждом клиентском ПК:

1. Добавьте `<vm-ip>` в список DNS-серверов (**первым**).
2. Проверьте:

```cmd
nslookup datalens.internal
curl -k https://datalens.internal
```

3. Откройте в браузере `https://datalens.internal`.
4. Примите предупреждение о самоподписанном сертификате.
5. Логин `admin`, пароль из `.env`.

Также можно обращаться к сайту **напрямую по IP** — `https://<vm-ip>` — без настройки DNS. Это удобно, если нужно быстро проверить доступ или DNS ещё не настроен.

---

## Часть 8. Проверка автозапуска

```bash
sudo systemctl is-enabled nginx dnsmasq docker
```

Все должны быть `enabled`. Если что-то `disabled`:

```bash
sudo systemctl enable nginx dnsmasq docker
```

Перезагрузите VM:

```bash
sudo reboot
```

После загрузки проверьте:

```bash
docker ps
sudo systemctl status nginx dnsmasq
```

Все контейнеры и сервисы должны подняться автоматически.

---

## Часть 9. Использование DataLens

### 9.1. Подключение к PostgreSQL

1. Создайте воркбук.
2. **Создать** → **Подключение** → **PostgreSQL**.
3. Параметры:
   - Хост: `host.docker.internal`
   - Порт: `5432`
   - База: `postgres`
   - Пользователь: `postgres`
   - Пароль: `<db-password>`
4. Проверить подключение → Создать.

### 9.2. Датасет и чарт

1. Внутри подключения → **Создать датасет**.
2. Перетащите нужные таблицы.
3. Сохраните → **Создать чарт**.
4. Постройте график (например, `manager` × `sum(amount)`).
5. Сохраните.

---

## Итог

Стенд готов. Доступ:

- `https://datalens.internal` — с любого ПК, где DNS указывает на `<vm-ip>`.
- `https://<vm-ip>` — прямой доступ по IP.
- `admin` / пароль из `.env` — учётные данные; либо зарегистрироваться
