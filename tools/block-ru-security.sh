#!/bin/bash
# Block Kaspersky (AS200107) + JSC Solar Security (ORG-JS257-RIPE)
# Источник: RIPE stat / apps.db.ripe.net, актуально на 2026-05-19.
# Перезапускай раз в неделю/месяц - префиксы меняются.

set -e

# === IPv4 ===
KASP_V4=(
  37.203.128.0/24 37.203.129.0/24
  77.74.176.0/24 77.74.177.0/24 77.74.178.0/23 77.74.180.0/24
  77.74.181.0/24 77.74.182.0/24 77.74.183.0/24
  79.133.168.0/23 79.133.170.0/23
  82.202.184.0/23
  93.159.227.0/24 93.159.228.0/23 93.159.230.0/23
  185.54.220.0/24 185.54.221.0/24 185.54.222.0/24 185.54.223.0/24
  185.85.12.0/24 185.85.14.0/24 185.85.15.0/24
  185.201.0.0/24 185.201.1.0/24 185.201.2.0/24 185.201.3.0/24
  193.238.132.0/23
  195.128.246.0/24 195.128.247.0/24
)

SOLAR_V4=(
  93.185.164.0/24
  193.200.12.0/24
  193.200.13.0/24
)

# === IPv6 (Kaspersky) ===
KASP_V6=(
  2a03:2480:68::/48 2a03:2480:69::/48 2a03:2480:70::/48
  2a03:2480:80::/48
  2a03:2480:8000::/48 2a03:2480:8010::/48 2a03:2480:8012::/47
  2a03:2480:8020::/48 2a03:2480:8021::/48 2a03:2480:8022::/48
  2a03:2480:8025::/48 2a03:2480:8026::/48 2a03:2480:8027::/48
  2a03:2480:8028::/48 2a03:2480:8029::/48
  2a03:2480:802a::/48 2a03:2480:802b::/48 2a03:2480:802d::/48
  2a03:2480:802f::/48
  2a03:2480:8030::/48 2a03:2480:8032::/48 2a03:2480:8033::/48
  2a03:2480:8034::/47 2a03:2480:8035::/48 2a03:2480:8036::/47
  2a03:2480:8037::/48
)

# === Apply ===
command -v ipset >/dev/null || { echo "ipset не установлен: apt install ipset"; exit 1; }

ipset create -exist block-ru-security  hash:net family inet  hashsize 1024 maxelem 1024
ipset create -exist block-ru-security6 hash:net family inet6 hashsize 1024 maxelem 1024

for n in "${KASP_V4[@]}" "${SOLAR_V4[@]}"; do
  ipset add -exist block-ru-security "$n"
done
for n in "${KASP_V6[@]}"; do
  ipset add -exist block-ru-security6 "$n"
done

# Drop в самом верху INPUT (раньше других правил)
iptables  -C INPUT -m set --match-set block-ru-security  src -j DROP 2>/dev/null \
  || iptables  -I INPUT 1 -m set --match-set block-ru-security  src -j DROP
ip6tables -C INPUT -m set --match-set block-ru-security6 src -j DROP 2>/dev/null \
  || ip6tables -I INPUT 1 -m set --match-set block-ru-security6 src -j DROP

# Сохранить, чтоб переживало рестарт (Debian/Ubuntu)
if command -v netfilter-persistent >/dev/null; then
  netfilter-persistent save
elif [[ -d /etc/iptables ]]; then
  iptables-save  > /etc/iptables/rules.v4
  ip6tables-save > /etc/iptables/rules.v6
  ipset save     > /etc/ipset.conf
fi

v4=$(ipset list block-ru-security  | sed -n '/^Members:/,$p' | tail -n +2 | wc -l)
v6=$(ipset list block-ru-security6 | sed -n '/^Members:/,$p' | tail -n +2 | wc -l)
echo "Готово: ${v4} v4 + ${v6} v6 префиксов в DROP"
