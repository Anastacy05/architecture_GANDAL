#!/usr/bin/env bash
# Bascule de la passerelle PAR DEFAUT d'une VM service, elle n'a qu'une seule patte donc pas besoin de verifier le reseau cible
#
# - /etc/failover/gateways-list : IP des routeurs du vnet (.1 a .10)
# - /etc/failover/node-id       : noeud de la VM = index de sa passerelle de base
#
# Regles :
#   1. la base repond                       -> on l'utilise (retour des qu'elle revient)
#   2. sinon, la passerelle courante repond -> on la garde
#   3. sinon, apres FAILS echecs de suite   -> premiere autre passerelle qui repond
set -u

NODE_ID_FILE=${NODE_ID_FILE:-/etc/failover/node-id}
GW_FILE=${GW_FILE:-/etc/failover/gateways-list}
IFACE=${IFACE:-enX0}
INTERVAL=${INTERVAL:-5}
FAILS=${FAILS:-3}
PROBE_DEST=${PROBE_DEST:-198.18.0.1}   # adresse lointaine bidon : sert a savoir quel "via" le noyau choisit

log() { echo "failover: $*"; }          # stdout -> journalctl -u failover

mapfile -t GW < <(sed 's/[[:space:]]//g' "$GW_FILE" | grep -E '^[0-9]+(\.[0-9]+){3}$')
NODE_ID=$(tr -dc '0-9' < "$NODE_ID_FILE")
if [ "${#GW[@]}" -eq 0 ] || [ -z "$NODE_ID" ] || [ "$NODE_ID" -ge "${#GW[@]}" ]; then
  log "node-id ('$NODE_ID') ou gateways-list invalide"; exit 1
fi

BASE=${GW[$NODE_ID]}
CAND=("$BASE")
for ip in "${GW[@]}"; do [ "$ip" != "$BASE" ] && CAND+=("$ip"); done
log "passerelle de base : $BASE (noeud $NODE_ID), interface $IFACE"

contains() { local x=$1; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# Passerelle que le noyau utilise vraiment pour sortir du vnet
current_gw() {
  ip -4 route get "$PROBE_DEST" 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}'
}

# Ping en parallele de toutes les candidates ; affiche celles qui repondent, par priorite
probe_all() {
  local tmp ip; tmp=$(mktemp -d)
  for ip in "${CAND[@]}"; do
    ( ping -n -q -c1 -W1 -w2 -I "$IFACE" "$ip" >/dev/null 2>&1 && touch "$tmp/$ip" ) &
  done
  wait
  for ip in "${CAND[@]}"; do [ -e "$tmp/$ip" ] && echo "$ip"; done
  rm -rf "$tmp"
}

apply() {
  if ip route replace default via "$1" dev "$IFACE"; then
    log "route par defaut via $1 (avant : ${CURRENT:-aucune})"
  else
    log "echec ip route replace via $1 (nouvel essai au prochain cycle)"
  fi
}

fails=0
while true; do
  # Pas encore d'IP (bail DHCP pas obtenu) : rien a faire
  if ! ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; then
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
      desired=${ALIVE[0]:-$BASE}
    elif [ "$fails" -ge "$FAILS" ] && [ "${#ALIVE[@]}" -gt 0 ]; then
      desired=${ALIVE[0]}
    fi
  fi
  if [ -n "$desired" ] && [ "$desired" != "$CURRENT" ]; then apply "$desired"; fi
  sleep "$INTERVAL"
done