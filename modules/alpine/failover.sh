#!/usr/bin/env bash
# Bascule de passerelle pour une VM alpine (routeur des reseaux users).
#
# L'alpine a UNE patte vers les pfSense (transit) et plusieurs pattes tenants. Ce script ne gere
# QUE la route sortante (ROUTE_DEST, "default" par defaut) qui doit passer par un pfSense vivant
# du vnet transit : tout ce qui n'est pas un tenant local part vers un pfSense, qui route ensuite
# vers l'infra, vers Internet ou vers l'alpine d'un autre noeud (route statique cote pfSense).
# Il n'y a PAS de bascule cote tenants : les VM users sont sur le meme noeud que leur alpine.
#
# - /etc/failover/gateways-list : une IP de pfSense par ligne (.1 a .N)
# - /etc/failover/node-id       : numero du noeud = index du pfSense de base
# - /etc/failover/env           : IFACE_MAC (MAC de la patte transit), ROUTE_DEST
#
# Regles :
#   1. le pfSense de base repond   -> on l'utilise (retour des qu'il revient)
#   2. sinon, le courant repond    -> on le garde
#   3. sinon, apres FAILS echecs de suite -> premier autre pfSense qui repond
set -u

[ -f /etc/failover/env ] && . /etc/failover/env

NODE_ID_FILE=${NODE_ID_FILE:-/etc/failover/node-id}
GW_FILE=${GW_FILE:-/etc/failover/gateways-list}
IFACE=${IFACE:-}
IFACE_MAC=${IFACE_MAC:-}
ROUTE_DEST=${ROUTE_DEST:-default}
INTERVAL=${INTERVAL:-5}   # secondes entre deux tests
FAILS=${FAILS:-3}         # echecs consecutifs avant de basculer

log() { echo "failover: $*"; }

mapfile -t GW < <(sed 's/[[:space:]]//g' "$GW_FILE" | grep -E '^[0-9]+(\.[0-9]+){3}$')
NODE_ID=$(tr -dc '0-9' < "$NODE_ID_FILE")

if [ "${#GW[@]}" -eq 0 ] || [ -z "$NODE_ID" ] || [ "$NODE_ID" -ge "${#GW[@]}" ]; then
  log "node-id ('$NODE_ID') ou gateways-list invalide"
  exit 1
fi

BASE=${GW[$NODE_ID]}
CAND=("$BASE")
for ip in "${GW[@]}"; do
  [ "$ip" != "$BASE" ] && CAND+=("$ip")
done
log "pfSense de base : $BASE (noeud $NODE_ID), route geree : $ROUTE_DEST"

contains() { local x=$1; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# Retrouve le nom de l'interface transit par sa MAC (enX0 sur Debian)
resolve_iface() {
  [ -n "$IFACE" ] && return 0
  [ -z "$IFACE_MAC" ] && return 1
  IFACE=$(ip -o link | awk -v m="${IFACE_MAC,,}" '
    { for (i = 1; i <= NF; i++) if (tolower($i) == m) { n = $2; sub(/:$/, "", n); sub(/@.*/, "", n); print n; exit } }')
  [ -n "$IFACE" ]
}

# Passerelle actuellement installee dans le noyau pour ROUTE_DEST
current_gw() {
  ip -4 route show exact "$ROUTE_DEST" dev "$IFACE" 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}'
}

# Teste toutes les IP en parallele et affiche celles qui repondent, par priorite
probe_all() {
  local tmp ip
  tmp=$(mktemp -d)
  for ip in "${CAND[@]}"; do
    ( ping -n -q -c1 -W1 -w2 -I "$IFACE" "$ip" >/dev/null 2>&1 && touch "$tmp/$ip" ) &
  done
  wait
  for ip in "${CAND[@]}"; do [ -e "$tmp/$ip" ] && echo "$ip"; done
  rm -rf "$tmp"
}

apply() {
  if ip route replace "$ROUTE_DEST" via "$1" dev "$IFACE"; then
    log "route $ROUTE_DEST via $1 (avant : ${CURRENT:-aucune})"
  else
    log "echec ip route replace via $1 (nouvel essai au prochain cycle)"
  fi
}

fails=0
while true; do
  # Interface transit pas encore la / pas encore d'IP : rien a faire
  if ! resolve_iface || ! ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; then
    sleep "$INTERVAL"; continue
  fi
  CURRENT=$(current_gw)
  mapfile -t ALIVE < <(probe_all)
  desired=""
  if contains "$BASE" "${ALIVE[@]}"; then
    desired=$BASE; fails=0
  elif [ -n "$CURRENT" ] && contains "$CURRENT" "${ALIVE[@]}"; then
    desired=$CURRENT; fails=0
  else
    fails=$((fails + 1))
    if [ -z "$CURRENT" ]; then
      desired=${ALIVE[0]:-$BASE}      # demarrage : on pose au moins la base
    elif [ "$fails" -ge "$FAILS" ] && [ "${#ALIVE[@]}" -gt 0 ]; then
      desired=${ALIVE[0]}
    fi
  fi
  if [ -n "$desired" ] && [ "$desired" != "$CURRENT" ]; then apply "$desired"; fi
  sleep "$INTERVAL"
done
