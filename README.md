# Свой сервер: защита и личный VPN

Два скрипта для нового VPS на Ubuntu 22.04 / 24.04 или Debian 12 / 13.

| Скрипт | Что делает |
|---|---|
| `scripts/harden.sh` | Первичная защита сервера: отдельный пользователь с sudo, вход только по ключу, SSH на другом порту, файрвол, fail2ban, автообновления безопасности |
| `scripts/vpn-setup.sh` | Личный VPN на Xray (VLESS + Reality, порт 443) без панели управления. Команды `vpn-add`, `vpn-del`, `vpn-list`, `vpn-show` |
| `client-configs/shadowrocket-*.conf` | Правила для Shadowrocket: своя страна напрямую, остальное через свой сервер (13 стран и вариант без разделения) |

Скрипты рассчитаны на отдельный свежий сервер. На сервер, где уже что-то работает, их лучше не запускать.

## Перед запуском

- SSH-ключ на своём компьютере. Если ключа ещё нет, создайте его (Mac, Linux, Windows 10/11 в PowerShell):

  ```
  ssh-keygen -t ed25519 -C "my-vps"
  ```

  На вопросы нажмите Enter. Если ключ уже есть, команда спросит, перезаписать ли его: ответьте `n`.

  Публичную половину скрипт попросит вставить. Показать её:

  ```
  cat ~/.ssh/id_ed25519.pub                       # Mac, Linux
  type $env:USERPROFILE\.ssh\id_ed25519.pub       # Windows, PowerShell
  ```

  Строка начинается с `ssh-ed25519`, копируйте её целиком. Файл `id_ed25519` без `.pub` — секретный, его никому не отправляйте.
- Доступ к консоли сервера в панели хостинга, на случай если что-то пойдёт не так.
- Если у хостинга есть свой файрвол в панели, откройте в нём порт SSH, который выберет скрипт, и TCP 443.

## 1. Защита сервера

Под root на сервере:

```
curl -fsSL https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/scripts/harden.sh -o harden.sh
bash harden.sh
```

Скрипт спросит имя нового пользователя, порт SSH и публичный ключ. В конце покажет команду для входа. Войдите из **второго** окна терминала, не закрывая первое, и выполните `sudo vps-confirm`. Если за 20 минут подтверждения не будет, SSH и файрвол сами вернутся к прежним настройкам.

После подтверждения перезагрузите сервер, чтобы обновления вступили в силу: `sudo reboot`.

## 2. Личный VPN

Под своим пользователем (не root) на сервере:

```
curl -fsSL https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/scripts/vpn-setup.sh -o vpn-setup.sh
sudo bash vpn-setup.sh
```

Через две-три минуты на экране будут ссылка `vless://` и QR-код для приложения. Устройства добавляются командой `sudo vpn-add ИМЯ`, по одному на каждое.

Приложения: iPhone — V2Box, Happ, Streisand, Shadowrocket; Android — Hiddify, v2rayNG; Windows и Mac — Hiddify.

## Своя страна напрямую (Shadowrocket)

Сайты и адреса вашей страны идут напрямую, остальное через свой сервер. Местные банки и сервисы видят обычный адрес, а локальный трафик не делает крюк.

В Shadowrocket: **Config** → «+» → вставить адрес файла своей страны → **Download** → **Use Config**, затем **Home** → **Global Routing** → **Config**.

| Страна | Адрес файла |
|---|---|
| Азербайджан | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-az.conf` |
| Армения | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-am.conf` |
| Германия | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-de.conf` |
| Грузия | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-ge.conf` |
| Израиль | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-il.conf` |
| Казахстан | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-kz.conf` |
| Кипр | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-cy.conf` |
| Кыргызстан | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-kg.conf` |
| Россия | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-ru.conf` |
| Сербия | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-rs.conf` |
| Таиланд | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-th.conf` |
| Турция | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-tr.conf` |
| Узбекистан | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-uz.conf` |
| Без разделения, всё через сервер | `https://raw.githubusercontent.com/aidobest/vps-guide/v0.3/client-configs/shadowrocket-all.conf` |

В каждом файле национальные домены страны и её адреса по базе GeoIP. В некоторых файлах дополнительно крупные местные сервисы на зарубежных доменах. Файлы собирает `client-configs/make-configs.py`.

## Почему `curl -o`, а не `curl | bash`

Скрипт задаёт вопросы, ему нужен ввод с клавиатуры. К тому же скачанный файл можно открыть и прочитать перед запуском: `less harden.sh`.

## Тесты

```
python3 tests/test_scripts.py
```

Все системные команды в тестах подменены, на машине ничего не меняется.

## Лицензия

MIT. Скрипты предоставляются как есть, без гарантий. Запуская их, вы сами отвечаете за свой сервер.
