#!/usr/bin/env python3
"""Генерирует правила Shadowrocket «своя страна напрямую, остальное через сервер».

Для каждой страны: её национальные домены и её адреса по базе GeoIP идут напрямую.
Российский файл (shadowrocket-ru.conf) ведётся вручную: там ещё список сервисов
на зарубежных доменах. Запуск: python3 client-configs/make-configs.py
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent

# код GeoIP → (название, национальные домены, включая кириллические/национальные в punycode)
COUNTRIES = {
    "kz": ("Казахстан", ["kz", "xn--80ao21a"]),   # .қаз
    "uz": ("Узбекистан", ["uz"]),
    "kg": ("Кыргызстан", ["kg"]),
    "am": ("Армения", ["am", "xn--y9a3aq"]),      # .հայ
    "ge": ("Грузия", ["ge", "xn--node"]),         # .გე
    "az": ("Азербайджан", ["az"]),
    "rs": ("Сербия", ["rs", "xn--90a3ac"]),       # .срб
    "tr": ("Турция", ["tr"]),
    "de": ("Германия", ["de"]),
    "cy": ("Кипр", ["cy"]),
    "il": ("Израиль", ["il"]),
    "th": ("Таиланд", ["th", "xn--o3cw4h"]),      # .ไทย
}

GENERAL = """[General]
bypass-system = true
skip-proxy = 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 127.0.0.1, localhost, *.local, captive.apple.com
tun-excluded-routes = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 255.255.255.255/32
dns-server = system
ipv6 = false
"""

LOCAL = """# Локальные сети
IP-CIDR,192.168.0.0/16,DIRECT
IP-CIDR,10.0.0.0/8,DIRECT
IP-CIDR,172.16.0.0/12,DIRECT
IP-CIDR,127.0.0.0/8,DIRECT
"""


def country(code: str, name: str, tlds: list[str]) -> str:
    domains = "\n".join(f"DOMAIN-SUFFIX,{t},DIRECT" for t in tlds)
    return f"""# Shadowrocket: {name} напрямую, всё остальное через свой сервер.
# Подключение к серверу добавляется отдельно по QR. Этот файл только про маршрутизацию.
# Сгенерирован make-configs.py. Правила читаются сверху вниз, первое совпавшее побеждает.

{GENERAL}
[Rule]
# Национальные домены
{domains}
# Всё, что физически в стране
GEOIP,{code.upper()},DIRECT
{LOCAL}# Остальное через свой сервер
FINAL,PROXY
"""


ALL = f"""# Shadowrocket: весь трафик через свой сервер, кроме локальной сети.
# Подключение к серверу добавляется отдельно по QR. Этот файл только про маршрутизацию.
# Сгенерирован make-configs.py.

{GENERAL}
[Rule]
{LOCAL}# Всё остальное через свой сервер
FINAL,PROXY
"""

if __name__ == "__main__":
    for code, (name, tlds) in COUNTRIES.items():
        (HERE / f"shadowrocket-{code}.conf").write_text(country(code, name, tlds))
    (HERE / "shadowrocket-all.conf").write_text(ALL)
    print(f"{len(COUNTRIES) + 1} файлов в {HERE}")
