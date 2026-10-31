# Routes et failover

Nombre d'hôtes = `length(hosts_name)` (N). Une alpine et un pfSense par hôte, `tenants_per_host` réseaux users par alpine.

| Équipement | IP | Route / rôle |
|---|---|---|
| Bastion (emilia, unique) | gestion `.11`, WAN DHCP | DHCP de gestion (baux fixes des N pfSense par MAC). `internal_cidr` via pfSense de gestion, **failover** (base = pfSense 0) |
| pfSense n | `.(n+1)` sur chaque vnet d'infra | Aucune patte tenant. Une route statique /24 par tenant vers `ALPINE_<noeud du tenant>` (IP transit de l'alpine) |
| alpine n (Debian) | transit `.(11+n)`, `.1` sur chacun de ses tenants | `default` via un pfSense de transit, **failover** (base = pfSense n). Relais DHCP (dnsmasq) vers Kea. **nftables** : forward interdit entre deux interfaces tenants (tout ce qui n'est pas transit) |
| VM infra (services...) | sur leur vnet | passerelle = pfSense du vnet, **failover** existant |
| VM users | sur le noeud de leur alpine | passerelle = `.1` (alpine), pas de failover |

Chemins :
- user -> infra : VM -> alpine n -> pfSense (vivant) -> vnet cible
- infra -> user : VM -> pfSense -> route statique -> alpine du noeud du tenant -> VM
- user -> user (autre noeud) : alpine -> pfSense -> alpine de l'autre noeud (si la matrice l'autorise)
- DHCP user : VM -> alpine (relais, giaddr = `.1` du tenant) -> Kea via pfSense ; réponse Kea -> route statique -> alpine

Filtrage :
- alpine : une seule règle, aucun paquet ne passe d'un réseau user à un autre réseau user du même noeud. Un paquet user -> user d'un autre noeud part vers pfSense (autorisé par l'alpine), qui le bloque ou non selon vos règles.
- pfSense : tout le reste.

## svc-net (une VM par hôte, vnet SERVICES)

| Élément | Détail |
|---|---|
| IP | `.(11+n)` sur services, passerelle initiale = pfSense n, **failover** vers les pfSense (script existant) |
| bind9 | svc-net-0 = maître, tous les autres = esclaves ; zone `gandal.internal` (DDNS Kea -> maître) |
| Kea | svc-net-0 = primary, svc-net-1 = standby (hot-standby, listener HA :8001), svc-net-2+ = backup (reçoivent les baux, ne répondent pas). API Control Agent :8000 |
| NetBox | docker (netbox-docker), `http://<ip svc-net>:8081`, indépendant sur chaque noeud |
| Relais | les alpines et les pfSense relaient le DHCP vers **tous** les svc-net ; seul le primary (ou le standby si le primary tombe) répond |

## pfSense : synchronisation, Internet, règles

- **pfsync** : multicast sur GESTION entre tous les routeurs (sans pair unicast). Un échange qui sort par un routeur et revient par un autre retrouve son état. Les noms d'interfaces doivent être identiques sur tous les routeurs : c'est le cas car les VIF sont créées dans le même ordre.
- **Internet** : passerelle par défaut des pfSense = bastion (`BASTION`, gestion `.11`). Pas de NAT sur pfSense (NAT sortant désactivé) ; le bastion fait le masquerade vers son WAN. Règle sur chaque vnet (et sur TRANSIT pour les users) vers `INTERNET_NETS` = IPv4 publique.
- **Matrice** (`local.links`) :
  - gestion <-> tous
  - tous -> services
  - users <-> pools VPN (jamais la dmz vpn, jamais user <-> user)
  - dmz-vpn -> pools VPN
  - backend <-> stockage, ia <-> stockage
  - monitoring et traffic : rien de plus
- **Ping des routeurs** : uniquement depuis les vnets dont les VM utilisent le failover (`failover_vnets` = tous sauf les pools VPN).
- **DHCP** : les réponses de Kea vont à l'IP du relais (giaddr), pas à l'IP source de la requête : règles dédiées en entrée de SERVICES (vers chaque vnet relayé et vers les users) et en entrée de chaque vnet relayé (réponse qui arrive par un autre routeur).

## Accès navigateur depuis le Pool-wide vers les VM users

Poste (Pool-wide) -> bastion (enX0, route vers les réseaux users) -> masquerade sur gestion -> pfSense (gestion -> TENANT_NETS) -> alpine du noeud -> VM.
Retour : VM -> alpine -> pfSense (TENANT_NETS -> gestion) -> bastion -> poste. Aucune règle pfSense supplémentaire : la matrice (gestion <-> users) couvre les deux sens.
Le bastion ne route depuis le Pool-wide que vers `wan_access_cidrs` (réseaux users), en TCP sur `wan_access_dports`. Le reste de l'interne reste inaccessible sans passer par le bastion en SSH.
Prérequis côté Pool-wide : une route vers les réseaux users via l'IP WAN du bastion (sur le routeur du wifi ou sur les postes).
