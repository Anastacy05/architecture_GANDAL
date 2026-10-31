#!/usr/bin/env bash
# Bascule de passerelle pour la VM bastion.
#
# Le bastion garde sa route par defaut sur enX0 (WAN, DHCP). Ce script ne gere
# QUE la route vers les reseaux internes (INTERNAL_CIDR), qui doit passer par
# un routeur pfSense du vnet gestion.
#
# - /etc/failover/gateways-list : une IP de routeur par ligne (.1 a .10)
# - /etc/failover/node-id       : numero du noeud (0, 1, 2...) = index dans la
#                                 liste -> c'est la passerelle de base
#
# Regles :
#   1. la passerelle de base repond   -> on l'utilise (retour des qu'elle revient)
#   2. sinon, la courante repond      -> on la garde
#   3. sinon, apres FAILS echecs de suite -> premiere autre passerelle qui repond
set -u

NODE_ID_FILE=/etc/failover/node-id
GW_FILE=/etc/failover/gateways-list
IFACE=${IFACE:-enX1}
INTERNAL_CIDR=${INTERNAL_CIDR:-10.0.0.0/16}
INTERVAL=${INTERVAL:-5}   # secondes entre deux tests
FAILS=${FAILS:-3}         # echecs consecutifs avant de basculer

log() { echo "failover: $*"; }   # stdout -> journalctl -u failover

mapfile -t GW < <(sed 's/[[:space:]]//g' "$GW_FILE" | grep -E '^[0-9]+(\.[0-9]+){3}$')
NODE_ID=$(tr -dc '0-9' < "$NODE_ID_FILE")

if [ "${#GW[@]}" -eq 0 ] || [ -z "$NODE_ID" ] || [ "$NODE_ID" -ge "${#GW[@]}" ]; then
  log "node-id ('$NODE_ID') ou gateways-list invalide"
  exit 1
fi

BASE=${GW[$NODE_ID]}
CAND=("$BASE")                      # ordre de priorite : base d'abord
for ip in "${GW[@]}"; do
  [ "$ip" != "$BASE" ] && CAND+=("$ip")
done
log "passerelle de base : $BASE (noeud $NODE_ID), reseaux internes : $INTERNAL_CIDR"

contains() { local x=$1; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# Teste toutes les IP en parallele (les .4 a .10 n'existent pas : ca evite
# d'attendre leur timeout une par une) et affiche celles qui repondent,
# dans l'ordre de priorite.
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
  if ip route replace "$INTERNAL_CIDR" via "$1" dev "$IFACE"; then
    log "route $INTERNAL_CIDR via $1 (avant : ${CURRENT:-aucune})"
    CURRENT=$1
  else
    log "echec ip route replace via $1 (nouvel essai au prochain cycle)"
  fi
}

CURRENT=""
fails=0
while true; do
  mapfile -t ALIVE < <(probe_all)
  desired=""
  if contains "$BASE" "${ALIVE[@]}"; then
    desired=$BASE; fails=0
  elif [ -n "$CURRENT" ] && contains "$CURRENT" "${ALIVE[@]}"; then
    desired=$CURRENT; fails=0
  else
    fails=$((fails + 1))
    if [ -z "$CURRENT" ]; then
      desired=${ALIVE[0]:-$BASE}    # demarrage : on pose au moins la base
    elif [ "$fails" -ge "$FAILS" ] && [ "${#ALIVE[@]}" -gt 0 ]; then
      desired=${ALIVE[0]}
    fi
  fi
  if [ -n "$desired" ] && [ "$desired" != "$CURRENT" ]; then apply "$desired"; fi
  sleep "$INTERVAL"
done