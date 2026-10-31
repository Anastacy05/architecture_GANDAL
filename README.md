# Architecture du datacenter (Terraform + Ansible sur XCP-ng / Xen Orchestra)

Un pool XCP-ng de N hôtes (`hosts_name`, par défaut emilia, jade, rem). Tout ce qui est « par noeud » suit `length(hosts_name)` : aucun nombre d'hôtes n'est écrit en dur.

## Vue d'ensemble

| Élément | Combien | Rôle |
|---|---|---|
| Bastion | 1, sur emilia | DHCP de gestion pour les pfSense, NAT vers Internet, accès SSH et navigateur depuis le Pool-wide |
| pfSense | 1 par hôte | Routeur et pare-feu des vnets d'infra. États synchronisés par pfsync |
| alpine (VM Debian) | 1 par hôte | Passerelle des réseaux users de son hôte (relais DHCP, une règle nftables, failover vers les pfSense) |
| svc-net | 1 par hôte | bind9, Kea, NetBox (+ agent réseau, hors de ce dépôt) |
| Réseaux users (tenants) | `tenants_per_host` par hôte | Internes à un hôte. Les VM users doivent être créées sur l'hôte de leur alpine |

Le détail des routes, du failover et des flux est dans `ROUTES.md`.

## Arborescence

```
main.tf                  racine : locals (vnets, matrice de flux), appels de modules, sorties
modules/vnets            réseaux privés (VXLAN) et réseaux tenants (internes à un hôte)
modules/bastion          bastion unique : dnsmasq (DHCP gestion), NAT, failover
modules/routeur          VM pfSense + playbook Ansible (interfaces, relais DHCP, pfsync, routes, règles)
modules/alpine           passerelles des réseaux users
modules/services         svc-net
```

## Prérequis

- Terraform >= 1.5 (blocs `check` et `moved`), provider `vatesfr/xenorchestra ~> 0.29.0`.
- Sur la machine qui lance Terraform : `ansible-playbook`, la collection `pfsensible.core` (`ansible-galaxy collection install pfsensible.core`) et `sshpass`.
- Dans Xen Orchestra : un pool nommé `Pool`, le stockage `Local Storage`, le réseau `Pool-wide network 0` (WAN du bastion), et les templates :
  - `Debian-Template-Base` (cloud-init + ssh, avec accès Internet pour `apt`) : bastion, alpines, svc-net ;
  - `PfSense-Template-Base` : routeurs. Sa première interface doit obtenir son IP par DHCP ; l'utilisateur est `admin` / `admin` (mot de passe d'usine, utilisé par le playbook).
- L'utilisateur du template Debian doit autoriser l'authentification SSH par mot de passe (le bastion l'active via cloud-init) ; son nom est `bastion_ssh_user` dans `main.tf` (`debian` par défaut).

## Variables et secrets

```bash
export TF_VAR_bastion_ssh_password='...'          # obligatoire : mot de passe du user de la VM bastion (rebond Ansible)
# valeurs par défaut = placeholders de l'équipe, à changer :
export TF_VAR_netbox_superuser_password='...'
export TF_VAR_netbox_api_token='...'               # 40 caractères
export TF_VAR_kea_api_password='...'
```

La connexion à Xen Orchestra est dans le bloc `provider` de `main.tf` (URL, utilisateur, mot de passe : à adapter).

Paramètres à connaître dans `main.tf` :

| Variable | Effet |
|---|---|
| `hosts_name` | liste des hôtes ; ajouter un hôte ajoute un pfSense, une alpine, un svc-net et ses réseaux users |
| `tenants_per_host` | réseaux users par alpine (`tenant_count = tenants_per_host × hôtes`) |
| `pfsync_vnet` | vnet qui porte la synchronisation pfsync (`gestion`) |
| `failover_vnets` | vnets dont les VM utilisent le failover (les routeurs y répondent au ping) |
| `links` | matrice des flux autorisés entre vnets, sans restriction de port |
| `wan_access_cidrs` / `wan_access_dports` (module bastion) | réseaux et ports joignables depuis le Pool-wide par le navigateur |

## Déploiement

```bash
terraform init
terraform plan
terraform apply
```

Ordre logique (géré par les dépendances) : réseaux, bastion, pfSense (le playbook attend que le routeur obtienne son IP du bastion, jusqu'à 15 min), alpines, svc-net.

Après un `apply`, `terraform output tenant_placement` donne, pour chaque réseau user, l'hôte où créer les VM, le réseau à utiliser et la passerelle (`.1`, l'alpine). Les VM users n'ont pas de script de failover.

## Points à vérifier au premier lancement

- **Hooks Kea** : `libdhcp_ha.so` et `libdhcp_lease_cmds.so` sont chargés par leur nom (répertoire par défaut de Kea). Si le paquet Debian ne les fournit pas, Kea ne démarre pas en HA.
- **Limite de VIF XCP-ng** : une alpine porte `tenants_per_host + 1` interfaces, un pfSense en porte 12.
- **Module `pfsensible.core`** : la syntaxe `alias:port` des règles DHCP et les paramètres `defaultgw` / `monitor_disable` des passerelles n'ont pas été exécutés.
- **pfsync** : multicast sur le vnet choisi ; les noms d'interfaces doivent être identiques sur tous les routeurs (création des VIF dans le même ordre).
- **Accès Pool-wide** : une route vers les réseaux users via l'IP WAN du bastion (réserver ce bail DHCP).
- **Dépendances externes au démarrage** : `apt`, `get.docker.com` et GitHub (NetBox) nécessitent l'accès Internet via pfSense puis le bastion.
- **Plan d'adressage** : `gandal_cidr` et `users_cidr` ne sont plus utilisés ; les tenants occupent `10.30.20.0/24` et suivants (un /24 par tenant).
