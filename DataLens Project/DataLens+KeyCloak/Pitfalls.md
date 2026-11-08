# Грабли развёртывания (REDOS, Nginx, Keycloak 26)

Проблемы, которые реально встретились при поднятии контура из [README](README.md). Симптом → почему → что сделать.

---

## Репозитории и DNS

### В клоне DataLens нет `deploy/`

Официальный репозиторий — [datalens-tech/datalens](https://github.com/datalens-tech/datalens). Там UI и `init.sh`. Keycloak, oauth2-proxy и Nginx собираются отдельно в `/opt/idp`. Искать compose IdP внутри DataLens бессмысленно.

### ВМ с DNS `<vm-ip>`

ВМ не должна указывать себя nameserver’ом. LDAP, yum и `quay.io` идут в корпоративные `<corp-dns-servers>`. Имена `datalens.internal` / `auth.internal` на ВМ — только `/etc/hosts`.

`nameserver 127.0.0.53` — stub `systemd-resolved`, не «ВМ резолвит сама себя».

### dnsmasq «чтобы резолвились свои имена»

Не нужен, пока жив AD DNS. `server=127.0.0.53` в dnsmasq — петля со stub. `127.0.0.1 datalens.internal` в hosts — ПК и соседи не попадут на ВМ.

`nslookup` на Windows не читает hosts. Пока нет A-записей в AD, смотреть `ping` / браузер.

---

## Nginx и SELinux

### `nginx: open() "/etc/nginx/conf.d/datalens.conf" failed (13: Permission denied)`

Файл создали через `tee`, контекст SELinux не `httpd_config_t`.

```bash
sudo chmod 644 /etc/nginx/conf.d/datalens.conf
sudo chown root:root /etc/nginx/conf.d/datalens.conf
sudo restorecon -Rv /etc/nginx /etc/nginx/certs
sudo nginx -t && sudo systemctl start nginx
```

Сертификаты из `/opt/idp` — тот же Permission denied на `.crt`/`.key`: `restorecon` и при необходимости `chcon -t httpd_config_t`.

### 502 от Nginx на UI / oauth2 / Keycloak

Нет `sudo setsebool -P httpd_can_network_connect 1`, либо на localhost не слушают 4180 / 8081 / 8080.

### Второй `server` без `listen 443 ssl`

`location` стоит до `server_name`, нет `listen 443 ssl` — `auth.internal` не поднимается. В каждом `server` сначала `listen`, `server_name`, сертификаты, потом `location`.

---

## oauth2-proxy не стартует / 500 до логина

### `cookie_secret must be 16, 24, or 32 bytes, but is 44`

`openssl rand -base64 32` даёт 44 символа. Нужно `openssl rand -hex 16` (32 символа). После правки `.env`:

```bash
docker compose --env-file .env up -d --force-recreate oauth2-proxy
```

Обычный `up -d` контейнер часто **не** пересоздаёт, секрет остаётся старым.

### Нет email у пользователя Keycloak

`Error creating session` / нет валидного email. У `localtest` задать Email и Email verified. Для AD без атрибута mail в compose: `OAUTH2_PROXY_OIDC_EMAIL_CLAIM: preferred_username`.

### `audience claims [aud] do not exist`

Keycloak 26 кладёт в access token `azp`, но не `aud`. oauth2-proxy сессию не создаёт. Mapper типа **Audience** (не Audience Resolve), Included Custom Audience `datalens`, в access и ID token.

Один и тот же timestamp в логе — старая попытка. Нужен новый вход в инкогнито.

### 403 `[AuthFailure] Invalid authentication via OAuth2: unauthorized`

Keycloak пустил, oauth2-proxy нет. В токене роль `viewer`, в compose ещё `datalens.viewer`. Сверить:

```bash
docker compose exec oauth2-proxy env | grep ALLOWED
```

Должно быть `viewer,editor,admin`. Recreate контейнера.

### Callback на `/favicon.ico`, `Error while parsing OAuth2 state: invalid length`

Chrome параллельно запрашивает иконку, стартует **второй** OAuth, `state` указывает на favicon. В Nginx:

```nginx
location = /favicon.ico {
    auth_request off;
    return 204;
}
```

### `WARNING: Multiple cookies … exceed the 4kb cookie limit`

В cookie лежат access + id + refresh. Сессия рвётся. `OAUTH2_PROXY_SESSION_COOKIE_MINIMAL: "true"` и увеличенные буферы Nginx (`proxy_buffer_size`, `large_client_header_buffers`).

---

## LDAP и роли Keycloak

### Sync: `0 users added, 0 updated, 0 removed, 0 failed`

Bind к DC живой, поиск пустой (или Import users Off). Часто в Users DN всё ещё пример `OU=Users,DC=corp,DC=local`.

Сначала `ldapsearch` с **теми же** URL, Bind DN и Users DN. Пусто — неверный DN или нет Read у сервисной учётки. Есть `dn:` — в Keycloak Search scope **Subtree**, фильтр пустой, Import users On.

`whoami /fqdn` и `dsquery user -name %username%` на Windows дают реальный DN; в Users DN — родитель, не сам CN.

### «Не могу вставить client secret в Keycloak»

В Keycloak 26 секрет только смотрят и жмут Regenerate. Копировать **из** Credentials **в** `.env`, не наоборот.

### `Could not create mapping: There is no role corresponding to configured value`

В Select Role выбраны чипы клиента `datalens` + `viewer`. Нужна **realm role** с именем `viewer`, фильтр **Filter by realm roles**. Имя `datalens.viewer` не использовать: realm уже называется `datalens`.

### Не пускает AD, `localtest` пускает

Стек nginx/oauth2 живой. Ломается только поиск/bind LDAP. В форму — `sAMAccountName` без `DOMAIN\`.

### Не пускает никто, обе формы «Invalid credentials»

Сначала `localtest` в realm **datalens** (не master). Если и он не входит — клиент, redirect URI, секрет, Audience.

---

## Выход

### `ERR_TOO_MANY_REDIRECTS` на `/oauth2/sign_out`

oauth2-proxy чистит split-cookie цепочкой 302 на тот же URL. Logout **не** проксировать в oauth2-proxy: `location = /oauth2/sign_out` в Nginx гасит cookie и редиректит на Keycloak logout.

### После sign_out снова тот же пользователь без формы

Cookie oauth2-proxy сняли, SSO Keycloak на `auth.internal` жива. `SKIP_PROVIDER_BUTTON` сразу логинит снова. Нужен редирект на `/realms/datalens/protocol/openid-connect/logout` и кнопка Logout на странице Keycloak.

### `400 Bad Request` на Keycloak logout

В URL были `client_id` и `post_logout_redirect_uri`. Keycloak 26 в этом случае требует `id_token_hint`. При `SESSION_COOKIE_MINIMAL` токена в cookie нет. Logout **без** query string.

### Cookie не удаляются, пока не сотрёшь вручную в Chrome

Nginx слал `Set-Cookie … Domain=datalens.internal; Max-Age=0`. oauth2-proxy ставит **host-only** cookie (без Domain). Для браузера это разные cookie. Стирать **без** `Domain=`.

После смены схемы logout один раз: Application → Clear site data для `datalens.internal` и `auth.internal`.

### Кнопка «Войти в DataLens» только если прокрутить вниз

`sub_filter` вставляет ссылку перед `</body>`, страница Keycloak уже на 100vh. Нужен `position:fixed` (например `top:72%`), иначе кнопка под фоном.

---

## Поведение DataLens (не баги стека)

- В шапке нет «сменить учётку» — выключен `datalens-auth`. Кнопка «Выйти» рисуется Nginx.
- Воркбук, созданный под AD, виден под `localtest` — общий каталог OSS без ACL.
- `admin` Keycloak в DataLens не входит.

Персональные пространства на сотрудника в этом контуре не сделать: нужен коммерческий DataLens On-Premises с нативным OIDC на тот же Keycloak.
