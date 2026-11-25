#!/bin/sh
set -e

# Переменные окружения (задаются в /container/envs на MikroTik)
WG_ADDR="${WG_ADDR:-10.2.1.24/24}"
WG_PRIVKEY="${WG_PRIVKEY:?WG_PRIVKEY is required}"
WG_PEER_PUBKEY="${WG_PEER_PUBKEY:?WG_PEER_PUBKEY is required}"
WG_PSK="${WG_PSK:-}"
WG_MTU="${WG_MTU:-1420}"

AWG_REMOTE="${AWG_REMOTE:?AWG_REMOTE (ip:port) is required}"
AWG_LOCAL_PORT="${AWG_LOCAL_PORT:-51820}"
AWG_PARAMS="${AWG_PARAMS:-}"

DNSPBR_LISTEN="${DNSPBR_LISTEN:-0.0.0.0}"
DNSPBR_PORT="${DNSPBR_PORT:-53}"
DNSPBR_UPSTREAM="${DNSPBR_UPSTREAM:-9.9.9.10}"
DNSPBR_RANGE="${DNSPBR_RANGE:-10.64.0.0/15}"
DNSPBR_MARK="${DNSPBR_MARK:-0x100}"
DNSPBR_TABLE="${DNSPBR_TABLE:-dnsmap}"
DNSPBR_ROUTE_TABLE="${DNSPBR_ROUTE_TABLE:-100}"
DNSPBR_INTERFACE="${DNSPBR_INTERFACE:-wg0}"

cleanup() {
    echo "Stopping services..."
    kill "$DNSPBR_PID" "$AWG_PID" 2>/dev/null || true
    ip link del wg0 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# 1. Запускаем awg-proxy (слушает локально 127.0.0.1:AWG_LOCAL_PORT, шлёт на AWG_REMOTE)
/usr/local/bin/awg-proxy \
    -l "127.0.0.1:${AWG_LOCAL_PORT}" \
    -r "${AWG_REMOTE}" \
    ${AWG_PARAMS} &
AWG_PID=$!

# 2. Поднимаем ядерный интерфейс wg0
ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
ip address add "${WG_ADDR}" dev wg0
ip link set mtu "${WG_MTU}" up dev wg0

WG_CONF="/tmp/wg0.conf"
cat > "${WG_CONF}" <<EOF
[Interface]
PrivateKey = ${WG_PRIVKEY}

[Peer]
PublicKey = ${WG_PEER_PUBKEY}
Endpoint = 127.0.0.1:${AWG_LOCAL_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

if [ -n "${WG_PSK}" ]; then
    echo "PresharedKey = ${WG_PSK}" >> "${WG_CONF}"
fi

wg setconf wg0 "${WG_CONF}"
rm -f "${WG_CONF}"

# 3. Маршрутизация через таблицу PBR и базовый NAT (nftables)
ip route replace default dev "${DNSPBR_INTERFACE}" table "${DNSPBR_ROUTE_TABLE}"

# Удаляем старое правило по метке, если перезапускаем скрипт в том же netns, и ставим свежее
ip rule del fwmark "${DNSPBR_MARK}" lookup "${DNSPBR_ROUTE_TABLE}" 2>/dev/null || true
ip rule add fwmark "${DNSPBR_MARK}" lookup "${DNSPBR_ROUTE_TABLE}" pref 100

nft -f - <<EOF
flush ruleset
table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wg0" masquerade
        oifname "eth0" masquerade
    }
}
EOF

# 4. Запускаем dnspbr с маркировкой пакетов
/usr/local/bin/dnspbr \
  -a "${DNSPBR_LISTEN}" \
  -p "${DNSPBR_PORT}" \
  -u "${DNSPBR_UPSTREAM}" \
  -r "${DNSPBR_RANGE}" \
  -m "${DNSPBR_MARK}" \
  -t "${DNSPBR_TABLE}" \
  -T "${DNSPBR_ROUTE_TABLE}" \
  -i "${DNSPBR_INTERFACE}"
DNSPBR_PID=$!

wait -n "$AWG_PID" "$DNSPBR_PID" 2>/dev/null || wait "$AWG_PID"
