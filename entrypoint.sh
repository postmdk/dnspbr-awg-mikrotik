#!/bin/sh
set -e

# Переменные окружения (задаются в /container/envs на MikroTik)
AWG_ADDR="${AWG_ADDR:-10.7.1.6/24}"
AWG_CLIENT_PRIV="${AWG_CLIENT_PRIV:?AWG_CLIENT_PRIV is required}"
AWG_CLIENT_PUB="${AWG_CLIENT_PUB:?AWG_CLIENT_PUB is required}"
AWG_SERVER_PUB="${AWG_SERVER_PUB:?AWG_SERVER_PUB is required}"
AWG_PSK="${AWG_PSK:-}"
AWG_MTU="${AWG_MTU:-1420}"

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

# Docker-интерфейс и отдельная таблица для транзитного трафика.
DOCKER_INTERFACE="${DOCKER_INTERFACE:-eth0}"
DOCKER_ROUTE_TABLE="${DOCKER_ROUTE_TABLE:-101}"

AWG_PID=""
DNSPBR_PID=""

cleanup() {
    echo "Stopping services..."
    [ -n "${DNSPBR_PID}" ] && kill "${DNSPBR_PID}" 2>/dev/null || true
    [ -n "${AWG_PID}" ] && kill "${AWG_PID}" 2>/dev/null || true

    ip rule del iif "${DOCKER_INTERFACE}" lookup "${DOCKER_ROUTE_TABLE}" 2>/dev/null || true
    ip -6 rule del iif "${DOCKER_INTERFACE}" lookup "${DOCKER_ROUTE_TABLE}" 2>/dev/null || true
    ip rule del fwmark "${DNSPBR_MARK}" lookup "${DNSPBR_ROUTE_TABLE}" 2>/dev/null || true

    nft delete table inet awg_nat 2>/dev/null || true
    ip link del wg0 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# 1. Запускаем awg-proxy.
# Его соединение с AWG_REMOTE должно оставаться вне VPN.
/usr/local/bin/awg-proxy \
    -l "127.0.0.1:${AWG_LOCAL_PORT}" \
    -r "${AWG_REMOTE}" \
    ${AWG_PARAMS} &
AWG_PID=$!

# 2. Поднимаем WireGuard-интерфейс.
ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
ip address add "${AWG_ADDR}" dev wg0
ip link set mtu "${AWG_MTU}" up dev wg0

WG_CONF="/tmp/wg0.conf"
cat > "${WG_CONF}" <<EOF
[Interface]
PrivateKey = ${AWG_CLIENT_PRIV}

[Peer]
PublicKey = ${AWG_SERVER_PUB}
Endpoint = 127.0.0.1:${AWG_LOCAL_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

if [ -n "${AWG_PSK}" ]; then
    echo "PresharedKey = ${AWG_PSK}" >> "${WG_CONF}"
fi

wg setconf wg0 "${WG_CONF}"
rm -f "${WG_CONF}"

# 3. Закрепляем маршрут до AWG-сервера через исходный Docker-шлюз.
# Это исключение обязательно: awg-proxy должен доставлять транспортные
# UDP-пакеты до сервера через eth0, а не пытаться отправить их в wg0.
case "${AWG_REMOTE}" in
    \[*\]:*)
        AWG_REMOTE_HOST="${AWG_REMOTE#\[}"
        AWG_REMOTE_HOST="${AWG_REMOTE_HOST%%\]*}"
        ;;
    *)
        AWG_REMOTE_HOST="${AWG_REMOTE%:*}"
        ;;
esac

ENDPOINT_ROUTE="$(ip route get "${AWG_REMOTE_HOST}" 2>/dev/null | head -n 1 || true)"
ENDPOINT_GW=""
ENDPOINT_DEV=""

set -- ${ENDPOINT_ROUTE}
while [ "$#" -gt 0 ]; do
    case "$1" in
        via)
            ENDPOINT_GW="$2"
            shift 2
            ;;
        dev)
            ENDPOINT_DEV="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ -z "${ENDPOINT_DEV}" ]; then
    echo "ERROR: cannot determine route to AWG_REMOTE=${AWG_REMOTE_HOST}"
    exit 1
fi

case "${AWG_REMOTE_HOST}" in
    *:*)
        if [ -n "${ENDPOINT_GW}" ]; then
            ip -6 route replace "${AWG_REMOTE_HOST}/128" via "${ENDPOINT_GW}" dev "${ENDPOINT_DEV}"
        else
            ip -6 route replace "${AWG_REMOTE_HOST}/128" dev "${ENDPOINT_DEV}"
        fi
        ;;
    *)
        if [ -n "${ENDPOINT_GW}" ]; then
            ip route replace "${AWG_REMOTE_HOST}/32" via "${ENDPOINT_GW}" dev "${ENDPOINT_DEV}"
        else
            ip route replace "${AWG_REMOTE_HOST}/32" dev "${ENDPOINT_DEV}"
        fi
        ;;
esac

# 4. Весь исходящий трафик самого контейнера направляем через wg0.
ip route replace default dev wg0
ip -6 route replace default dev wg0

# 5. Весь транзитный трафик, пришедший с Docker-интерфейса,
# также направляем через wg0.
ip route replace default dev wg0 table "${DOCKER_ROUTE_TABLE}"
ip -6 route replace default dev wg0 table "${DOCKER_ROUTE_TABLE}"

ip rule del iif "${DOCKER_INTERFACE}" lookup "${DOCKER_ROUTE_TABLE}" 2>/dev/null || true
ip rule add iif "${DOCKER_INTERFACE}" lookup "${DOCKER_ROUTE_TABLE}" pref 300

ip -6 rule del iif "${DOCKER_INTERFACE}" lookup "${DOCKER_ROUTE_TABLE}" 2>/dev/null || true
ip -6 rule add iif "${DOCKER_INTERFACE}" lookup "${DOCKER_ROUTE_TABLE}" pref 300

# 6. Сохраняем существующую DNS PBR-маршрутизацию.
ip route replace default dev "${DNSPBR_INTERFACE}" table "${DNSPBR_ROUTE_TABLE}"

#ip rule del fwmark "${DNSPBR_MARK}" lookup "${DNSPBR_ROUTE_TABLE}" 2>/dev/null || true
#ip rule add fwmark "${DNSPBR_MARK}" lookup "${DNSPBR_ROUTE_TABLE}" pref 250

# 7. NAT на wg0. Не используем flush ruleset:
# чужие таблицы и правила nftables должны остаться нетронутыми.
nft delete table inet awg_nat 2>/dev/null || true
nft -f - <<EOF
table inet awg_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wg0" masquerade
    }
}
EOF

# 8. Запускаем dnspbr.
/usr/local/bin/dnspbr \
  -a "${DNSPBR_LISTEN}" \
  -p "${DNSPBR_PORT}" \
  -u "${DNSPBR_UPSTREAM}" \
  -r "${DNSPBR_RANGE}" \
#  -m "${DNSPBR_MARK}" \
#  -t "${DNSPBR_TABLE}" \
#  -T "${DNSPBR_ROUTE_TABLE}" \
#  -i "${DNSPBR_INTERFACE}" &
DNSPBR_PID=$!

wait -n "${AWG_PID}" "${DNSPBR_PID}" 2>/dev/null || wait "${AWG_PID}"
