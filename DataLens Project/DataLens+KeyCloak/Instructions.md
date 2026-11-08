# DataLens OSS + Keycloak + Nginx

Руководство по **идентичному** развёртыванию на одной ВМ REDOS Server (VMware, bridged).

Вход в Open Source DataLens — учётки Active Directory. Open Source DataLens LDAP/OIDC не умеет, поэтому:

```
Браузер
  → https://datalens.internal     Nginx :443
      → oauth2-proxy :4180
          → Keycloak https://auth.internal
              → LDAP ldap://<dc-ip>:389
          → DataLens :8080
```

Снаружи **Nginx**, не Traefik. Нативный `datalens-auth` выключен (`./init.sh --disable-auth --up`), иначе две формы логина.

Если что-то пойдёт не так — [Pitfalls.md](Pitfalls.md).

---

## Результат

| URL | Назначение |
| --- | --- |
| `https://datalens.internal` | UI DataLens (после логина Keycloak) |
| `https://auth.internal` | Админка Keycloak и форма входа |
| `https://datalens.internal/oauth2/sign_out` | Выход |

Оба имени резолвятся в **один** IP. Host-заголовок разделяет сервисы.

С `--disable-auth` внутри DataLens нет ACL: все, кого пустил Keycloak, видят общий каталог воркбуков.

---

## Площадка (эталон)

Подставьте свои адреса, если повторяете на другой сети. Ниже — плейсхолдеры вместо адресов рабочего контура.

| Параметр | Значение |
| --- | --- |
| ОС ВМ | REDOS Server, Docker + Compose + git уже стоят |
| Сеть ВМ | bridged, `<vm-ip>` |
| Хост Windows | `<host-ip>`, gateway `<gateway-ip>` |
| DNS ВМ и хоста | `<corp-dns-servers>` |
| LDAP | `ldap://<dc-ip>:389` |
| DataLens | [datalens-tech/datalens](https://github.com/datalens-tech/datalens) |
| Каталог DataLens | `/opt/datalens` |
| Каталог авторизации | `/opt/idp` (Keycloak, Postgres, oauth2-proxy) |

В клоне DataLens **нет** Keycloak и Nginx. Они ставятся отдельно в `/opt/idp`.

На ВМ в качестве DNS **не** указывать `<vm-ip>`. Корпоративный DNS не менять.

---

## 0. Пакеты на ВМ

```bash
sudo dnf install -y nginx openssl
# если dnf нет: sudo yum install -y nginx openssl
```

Docker уже должен быть. Проверка: `docker compose version`.

```bash
sudo systemctl enable --now firewalld docker
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
sudo setsebool -P httpd_can_network_connect 1
```

Снаружи открыты только 80 и 443. Порты 8080, 4180, 8081 с LAN не публиковать.

---

## 1. DNS

**ВМ** — `/etc/hosts`:

```
<vm-ip>  datalens.internal auth.internal
```

`systemd-resolved` не трогать. `nameserver 127.0.0.53` в resolv.conf — stub, так и должно быть.

```bash
getent hosts datalens.internal auth.internal
```

Оба имени → `<vm-ip>`.

**Windows-хост** — от администратора `C:\Windows\System32\drivers\etc\hosts`, та же строка.

```powershell
ipconfig /flushdns
ping datalens.internal
```

`nslookup` смотрит только DNS-сервер и пока может сказать NXDOMAIN — это нормально, пока нет A-записей в AD. Для клиентов сети позже: две A-записи `datalens.internal` и `auth.internal` → `<vm-ip>` на `<corp-dns-servers>`. Hosts на ВМ оставить.

dnsmasq не ставить.

---

## 2. DataLens

```bash
sudo mkdir -p /opt
sudo chown "$USER:$USER" /opt
cd /opt
git clone https://github.com/datalens-tech/datalens.git datalens
cd datalens
./init.sh --disable-auth --up
```

Если DataLens уже стоит — в **его** каталоге ту же команду.

```bash
ss -lnt | grep 8080
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080
sudo ss -lntp | grep -E ':80|:443'
```

Ожидается слушатель 8080 и ответ 200/302. 80 и 443 свободны.

---

## 3. Секреты и сертификат

```bash
sudo mkdir -p /opt/idp/certs
sudo chown -R "$USER:$USER" /opt/idp
cd /opt/idp

echo "ADMIN=$(openssl rand -base64 18)"
echo "DB=$(openssl rand -base64 18)"
echo "CLIENT=$(openssl rand -hex 20)"
echo "COOKIE=$(openssl rand -hex 16)"
```

Сохраните `ADMIN` (вход в админку Keycloak). `COOKIE` — вывод `openssl rand -hex 16`, длина **32** символа. Не использовать `openssl rand -base64 32`.

```bash
openssl req -x509 -nodes -newkey rsa:4096 -days 825 \
  -keyout /opt/idp/certs/datalens.key \
  -out /opt/idp/certs/datalens.crt \
  -subj "/CN=datalens.internal" \
  -addext "subjectAltName=DNS:datalens.internal,DNS:auth.internal,IP:<vm-ip>"
chmod 600 /opt/idp/certs/datalens.key
```

```bash
cat > /opt/idp/.env <<'EOF'
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=
KEYCLOAK_DB_PASSWORD=
OAUTH2_PROXY_CLIENT_ID=datalens
OAUTH2_PROXY_CLIENT_SECRET=
OAUTH2_PROXY_COOKIE_SECRET=
LDAP_CONNECTION_URL=ldap://<dc-ip>:389
LDAP_BIND_DN=
LDAP_BIND_CREDENTIAL=
LDAP_USERS_DN=
LDAP_GROUPS_DN=
EOF
chmod 600 /opt/idp/.env
```

Впишите сгенерированные секреты. Bind DN, пароль сервисной учётки и Users DN — **ваши** из AD (`whoami /fqdn` и `dsquery user -samid %username%` на Windows). Users DN — родительская OU или корень домена, не `CN=` пользователя.

На этой площадке LDAP: **`ldap://<dc-ip>:389`**.

---

## 4. Compose: Keycloak + Postgres + oauth2-proxy

Файл `/opt/idp/docker-compose.yml`:

```yaml
name: datalens-idp

services:
  keycloak-db:
    image: docker.io/library/postgres:16.8-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
    volumes:
      - keycloak-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
      interval: 10s
      timeout: 5s
      retries: 10

  keycloak:
    image: quay.io/keycloak/keycloak:26.2.5
    restart: unless-stopped
    command: start
    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: ${KEYCLOAK_ADMIN}
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://keycloak-db:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
      KC_HOSTNAME: https://auth.internal
      KC_HOSTNAME_STRICT: "false"
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
      KC_HEALTH_ENABLED: "true"
    ports:
      - "127.0.0.1:8081:8080"
    volumes:
      - ./certs:/opt/keycloak/conf/truststores:ro
    depends_on:
      keycloak-db:
        condition: service_healthy

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.8.2
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
      - "auth.internal:host-gateway"
      - "datalens.internal:host-gateway"
    environment:
      OAUTH2_PROXY_HTTP_ADDRESS: 0.0.0.0:4180
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      OAUTH2_PROXY_CLIENT_ID: ${OAUTH2_PROXY_CLIENT_ID}
      OAUTH2_PROXY_CLIENT_SECRET: ${OAUTH2_PROXY_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${OAUTH2_PROXY_COOKIE_SECRET}
      OAUTH2_PROXY_COOKIE_SECURE: "true"
      OAUTH2_PROXY_COOKIE_HTTPONLY: "true"
      OAUTH2_PROXY_COOKIE_SAMESITE: lax
      OAUTH2_PROXY_COOKIE_PATH: /
      OAUTH2_PROXY_SESSION_COOKIE_MINIMAL: "true"
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_OIDC_ISSUER_URL: https://auth.internal/realms/datalens
      OAUTH2_PROXY_REDIRECT_URL: https://datalens.internal/oauth2/callback
      OAUTH2_PROXY_UPSTREAMS: http://host.docker.internal:8080
      OAUTH2_PROXY_REVERSE_PROXY: "true"
      OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
      OAUTH2_PROXY_CODE_CHALLENGE_METHOD: S256
      OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL: "true"
      OAUTH2_PROXY_OIDC_EMAIL_CLAIM: preferred_username
      OAUTH2_PROXY_OIDC_GROUPS_CLAIM: groups
      OAUTH2_PROXY_ALLOWED_ROLES: viewer,editor,admin
      OAUTH2_PROXY_SSL_INSECURE_SKIP_VERIFY: "true"
      OAUTH2_PROXY_LOGOUT_URL: https://auth.internal/realms/datalens/protocol/openid-connect/logout
      OAUTH2_PROXY_WHITELIST_DOMAINS: ".internal"
    ports:
      - "127.0.0.1:4180:4180"
    depends_on:
      - keycloak

volumes:
  keycloak-db:
```

`OAUTH2_PROXY_COOKIE_DOMAINS` не задавать.

```bash
cd /opt/idp
docker compose --env-file .env up -d
docker compose ps
```

Keycloak поднимается 1–2 минуты. После любой правки env oauth2-proxy:

```bash
docker compose --env-file .env up -d --force-recreate oauth2-proxy
```

---

## 5. Nginx

```bash
sudo mkdir -p /etc/nginx/certs
sudo cp /opt/idp/certs/datalens.crt /opt/idp/certs/datalens.key /etc/nginx/certs/
sudo chmod 600 /etc/nginx/certs/datalens.key
sudo restorecon -Rv /etc/nginx /etc/nginx/certs
```

Скопируйте [конфиг в конце файла](#конфиг-nginx) в `/etc/nginx/conf.d/datalens.conf` (`sudo tee` или редактор). Затем:

```bash
sudo chmod 644 /etc/nginx/conf.d/datalens.conf
sudo chown root:root /etc/nginx/conf.d/datalens.conf
sudo restorecon -Rv /etc/nginx
sudo nginx -t
sudo systemctl enable --now nginx
```

```bash
curl -kI https://auth.internal
curl -kI https://datalens.internal
```

---

## 6. Keycloak

Откройте `https://auth.internal` (принять самоподписанный сертификат). Войдите `admin` / `KEYCLOAK_ADMIN_PASSWORD`.

**Realm** — изолированный «тенант» внутри Keycloak: свои пользователи, клиенты, роли. `master` — только админка самого Keycloak. Всё для DataLens живёт в отдельном realm **datalens**, иначе oauth2-proxy ходил бы не туда, а учётки AD смешались бы с `admin`.

Дальше в консоли сверху слева всегда **datalens**, не `master`.

### 6.1. Realm и роли

Create realm → имя `datalens` → Create.

**Realm roles** → Create role, три штуки: `viewer`, `editor`, `admin`.

oauth2-proxy пускает на DataLens только тех, у кого в токене одна из этих ролей (`OAUTH2_PROXY_ALLOWED_ROLES`). Без роли Keycloak логин пройдёт, а UI отдаст 403.

Это **realm**-роли (общие для realm), не роли клиента. В Assign role / Select Role фильтр: **Filter by realm roles**.

### 6.2. Клиент oauth2-proxy

Клиент — регистрация приложения, которое ходит в Keycloak по OIDC. Здесь это oauth2-proxy: без клиента не будет redirect на форму и обмена `code` на токен.

Clients → Create client:

- Client ID: `datalens`
- Client authentication: **On**
- Standard flow: **On**
- Direct access grants: **Off**
- Valid redirect URIs: `https://datalens.internal/oauth2/callback`
- Web origins: `https://datalens.internal`

Секрет клиента должен совпасть с `OAUTH2_PROXY_CLIENT_SECRET`. Credentials → скопируйте **Client secret** в `.env` (в UI секрет вручную не вставляется). Затем `--force-recreate oauth2-proxy`.

Mappers дописывают в токен поля, которые читает oauth2-proxy:

- **User Realm Role** — claim `roles` со списком `viewer` / `editor` / `admin`.
- **Audience** — claim `aud=datalens`. Без него Keycloak 26 не кладёт `aud`, oauth2-proxy отвергает сессию.

Client scopes → клик **`datalens-dedicated`** → Mappers → Add mapper → **By configuration**:

| Тип | Поля |
| --- | --- |
| **User Realm Role** | Name `realm-roles`, Token Claim Name `roles`, Multivalued On, ID / access / userinfo On |
| **Audience** (не Audience Resolve) | Name `audience`, Included Custom Audience `datalens`, ID + access token On |

Audience через CLI, если удобнее:

```bash
cd /opt/idp
set -a && source .env && set +a
KC=$(docker compose ps -q keycloak)
docker exec "$KC" /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://127.0.0.1:8080 --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
CID=$(docker exec "$KC" /opt/keycloak/bin/kcadm.sh get clients -r datalens \
  -q clientId=datalens --fields id --format csv --noquotes | tail -1)
docker exec "$KC" /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models \
  -r datalens -s name=audience -s protocol=openid-connect \
  -s protocolMapper=oidc-audience-mapper \
  -s 'config."included.custom.audience"=datalens' \
  -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=true'
```

### 6.3. LDAP

User federation подключает AD: пароль проверяет каталог, Keycloak сам пароли AD не хранит. Edit mode **READ_ONLY** — в AD ничего не пишется.

Группы AD для входа не нужны: всем найденным пользователям вешается realm-роль `viewer` (Hardcoded LDAP Role Mapper).

User federation → Add LDAP:

| Поле | Значение |
| --- | --- |
| Vendor | Active Directory |
| Connection URL | `ldap://<dc-ip>:389` |
| Bind type | simple |
| Bind DN / credential | сервисная учётка |
| Edit mode | READ_ONLY |
| Users DN | ваш OU или `DC=…,DC=…` |
| Search scope | **Subtree** |
| Pagination | On |
| Username LDAP attribute | `sAMAccountName` |
| RDN LDAP attribute | `cn` |
| UUID LDAP attribute | `objectGUID` |
| User object classes | `person, organizationalPerson, user` |
| Custom user LDAP filter | пусто |
| Import users | **On** |
| Enabled | On |

Save → Test connection → Test authentication → Action → **Sync all users** (ожидается не ноль added).

Mapper:

User federation → LDAP → Mappers → Add mapper → тип **hardcoded-ldap-role-mapper** → Name `default-viewer` → Select Role → **Filter by realm roles** → **`viewer`** → Save.

Снова Sync all users. Users → доменный логин → Role mapping → есть `viewer`.

В форму входа — `sAMAccountName` без `DOMAIN\` и без UPN.

### 6.4. Контрольный локальный пользователь

`localtest` не из AD: им проверяют Nginx и oauth2-proxy отдельно от LDAP.

Users → Add user `localtest`, Email (любой, например `localtest@internal`), Email verified On → Create → Credentials, Temporary **Off** → Role mapping → Assign role → Filter by realm roles → `viewer`.

---

## 7. Проверка входа и выхода

С Windows, инкогнито:

1. `https://datalens.internal` — форма Keycloak, не логин DataLens.
2. `localtest`, затем свой `sAMAccountName`.
3. UI DataLens, справа внизу кнопка **Выйти**.
4. Страница Keycloak Logout → **Logout** → кнопка **Войти в DataLens** → снова форма логина.

Выход без кнопки: `https://datalens.internal/oauth2/sign_out`.

Админка Keycloak: `https://auth.internal` (`admin`). Прямой `http://<vm-ip>:8080` с ПК не использовать.

---

## Чеклист повтора

- [ ] DataLens `--disable-auth`, `:8080` отвечает
- [ ] Hosts на ВМ и ПК, DNS ВМ корпоративный
- [ ] `/opt/idp` up: postgres, keycloak, oauth2-proxy; Traefik нет
- [ ] Cookie secret 32 символа, `ALLOWED_ROLES=viewer,editor,admin`
- [ ] Nginx `nginx -t` ok, SELinux restorecon + `httpd_can_network_connect`
- [ ] Realm `datalens`, клиент, Audience, realm-роль `viewer`
- [ ] LDAP 389, sync не ноль, hardcoded `viewer`
- [ ] Вход AD, выход с подтверждением Keycloak, повторный вход — форма

---

## Конфиг Nginx

`/etc/nginx/conf.d/datalens.conf` — единственная точка входа с LAN: TLS, два имени на один IP, прокси на три бэкенда.

| Блок | Зачем |
| --- | --- |
| `upstream …` | Алиасы: oauth2-proxy `:4180`, DataLens `:8080`, Keycloak `:8081` (все на localhost) |
| `listen 80` | Редирект HTTP → HTTPS |
| `server datalens.internal` | Сайт DataLens: TLS, проверка сессии, прокси на UI |
| `location = /favicon.ico` | Отдаёт 204 без OAuth, чтобы Chrome не стартовал второй логин на иконку |
| `location = /oauth2/sign_out` | Гасит cookie сессии и отправляет на logout Keycloak (сам oauth2-proxy здесь зацикливается) |
| `location /oauth2/` | Callback и sign_in oauth2-proxy |
| `location = /oauth2/auth` | Внутренний запрос Nginx: «есть ли сессия?» (`auth_request`) |
| `location /` | Если сессии нет — на логин; если есть — на DataLens. `sub_filter` рисует кнопку «Выйти» |
| `server auth.internal` | Прокси на Keycloak |
| `location …/logout` | Страница «You are logged out» + кнопка «Войти в DataLens» |

Файл целиком:

```nginx
upstream datalens_oauth2 { server 127.0.0.1:4180; }
upstream datalens_ui     { server 127.0.0.1:8080; }
upstream keycloak_ui     { server 127.0.0.1:8081; }

server {
    listen 80;
    server_name datalens.internal auth.internal;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name datalens.internal;
    ssl_certificate     /etc/nginx/certs/datalens.crt;
    ssl_certificate_key /etc/nginx/certs/datalens.key;
    large_client_header_buffers 4 32k;

    location = /favicon.ico {
        auth_request off;
        access_log off;
        log_not_found off;
        return 204;
    }

    location = /oauth2/sign_out {
        auth_request off;
        add_header Set-Cookie "_oauth2_proxy=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        add_header Set-Cookie "_oauth2_proxy_0=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        add_header Set-Cookie "_oauth2_proxy_1=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        add_header Set-Cookie "_oauth2_proxy_2=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        add_header Set-Cookie "_oauth2_proxy_csrf=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        add_header Set-Cookie "_datalens_oauth2=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        add_header Set-Cookie "_datalens_oauth2_0=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        add_header Set-Cookie "_datalens_oauth2_csrf=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=lax" always;
        return 302 https://auth.internal/realms/datalens/protocol/openid-connect/logout;
    }

    location /oauth2/ {
        proxy_pass http://datalens_oauth2;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    location = /oauth2/auth {
        internal;
        proxy_pass http://datalens_oauth2;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Uri $request_uri;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
    }

    location / {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in;
        auth_request_set $user $upstream_http_x_auth_request_user;
        auth_request_set $email $upstream_http_x_auth_request_email;
        proxy_set_header X-Auth-Request-User $user;
        proxy_set_header X-Auth-Request-Email $email;
        proxy_pass http://datalens_ui;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_set_header Accept-Encoding "";
        sub_filter_types text/html;
        sub_filter_once on;
        sub_filter '</body>' '<a href="/oauth2/sign_out" style="position:fixed;right:16px;bottom:16px;z-index:99999;padding:8px 14px;background:#1a1a1a;color:#fff;border-radius:8px;font:14px/1.2 sans-serif;text-decoration:none;box-shadow:0 2px 8px rgba(0,0,0,.3)">Выйти</a></body>';
    }
}

server {
    listen 443 ssl;
    server_name auth.internal;
    ssl_certificate     /etc/nginx/certs/datalens.crt;
    ssl_certificate_key /etc/nginx/certs/datalens.key;
    large_client_header_buffers 4 32k;

    location ~* /openid-connect/logout {
        proxy_pass http://keycloak_ui;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Accept-Encoding "";
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        sub_filter_types text/html;
        sub_filter_once on;
        sub_filter '</body>' '<a href="https://datalens.internal/" style="position:fixed;left:50%;top:72%;transform:translate(-50%,0);z-index:99999;padding:12px 24px;background:#0066cc;color:#fff;border-radius:8px;font:16px/1.2 sans-serif;text-decoration:none;box-shadow:0 4px 16px rgba(0,0,0,.4)">Войти в DataLens</a></body>';
    }

    location / {
        proxy_pass http://keycloak_ui;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
```
