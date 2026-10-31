terraform {
  required_providers {
    xenorchestra = {
      source  = "vatesfr/xenorchestra"
      version = "~> 0.29.0"
    }
  }
}


# =========================================================================
# CONNEXION XEN ORCHESTRA
# =========================================================================

provider "xenorchestra" {
    url      = "ws://127.0.0.1:100"
    username = "admin@admin.net"
    password = "admin"
    insecure = true
}


# =========================================================================
# RESSOURCES XCP-ng EXISTANTES
# =========================================================================

data "xenorchestra_pool" "pool" {
    name_label = "Pool"
}


# =========================================================================
# SECRET : mot de passe de l'utilisateur de la VM bastion
#   export TF_VAR_bastion_ssh_password='...'
# =========================================================================

variable "bastion_ssh_password" {
  type      = string
  sensitive = true
}

# Secrets des svc-net (valeurs par defaut = placeholders de l'equipe : A CHANGER)
#   export TF_VAR_netbox_superuser_password='...'  TF_VAR_netbox_api_token='...'  TF_VAR_kea_api_password='...'
variable "netbox_superuser_password" {
  type      = string
  sensitive = true
  default   = "ChangeMeInProduction!"
}

variable "netbox_api_token" {
  type      = string
  sensitive = true
  default   = "0123456789abcdef0123456789abcdef01234567"
}

variable "kea_api_password" {
  type      = string
  sensitive = true
  default   = "ChangeMeKeaPass"
}


# =========================================================================
# VALEURS ET LISTES
# =========================================================================

locals {

  internal_cidr = "10.30.0.0/16"
  gandal_cidr = "10.30.0.0/19"
  users_cidr = "10.30.20.0/17"

  hosts_name = [ "emilia", "jade", "rem" ]

  # IP .1 a .10 de chaque vnet : reservees aux routeurs (pfSense .(noeud+1)) et aux candidats du failover
  # IP .11 et + : VM d'infra posees sur le vnet (bastion sur gestion, alpines sur transit)
  gateway_number   = 10

  # Reseaux users : 1 alpine par hote, chacune route EXACTEMENT tenants_per_host reseaux
  # -> le total suit la taille de hosts_name (ajouter un hote = ajouter une alpine et ses reseaux)
  tenants_per_host = 31
  tenant_count     = local.tenants_per_host * length(local.hosts_name)

  # 1 VM svc-net par hote (bind9 + Kea + NetBox + agent reseau) sur SERVICES : .11, .12, .13...
  svc_net_ips = [
    for n in range(length(local.hosts_name)) :
    cidrhost(local.vnets["services"].ip, local.gateway_number + n + 1)
  ]
  # DNS et DHCP tournent sur les memes VM : svc-net-0 = maitre DNS / primary Kea, svc-net-1 = standby Kea,
  # les suivants = esclaves DNS / backup Kea
  dns_ips  = local.svc_net_ips
  dhcp_ips = local.svc_net_ips
  # les reseaux cross server, bases sur une pif
  vnets = {
    gestion = {
      ip     = "10.30.0.0/24"
      name   = "GESTION"
      mac    = "02:00:00:00:00:00"
      ip_emi = "10.30.0.1"
      prefix = "24"
      role   = "gestion"
    }
    stockage = {
      ip     = "10.30.1.0/24"
      name   = "STOCKAGE"
      mac    = "02:00:00:00:00:01"
      ip_emi = "10.30.1.1"
      prefix = "24"
      role   = "stockage"
    }
    transit = {
      ip     = "10.30.2.0/24"
      name   = "TRANSIT"
      mac    = "02:00:00:00:00:02"
      ip_emi = "10.30.2.1"
      prefix = "24"
      role   = "transit"
    }
    services = {
      ip     = "10.30.3.0/24"
      name   = "SERVICES"
      mac    = "02:00:00:00:00:03"
      ip_emi = "10.30.3.1"
      prefix = "24"
      role   = "services"
    }
    monitoring = {
      ip     = "10.30.4.0/24"
      name   = "MONITORING"
      mac    = "02:00:00:00:00:04"
      ip_emi = "10.30.4.1"
      prefix = "24"
      role   = "monitoring"
    }
    backend = {
      ip     = "10.30.5.0/24"
      name   = "BACKEND"
      mac    = "02:00:00:00:00:05"
      ip_emi = "10.30.5.1"
      prefix = "24"
      role   = "backend"
    }
    ia = {
      ip     = "10.30.6.0/24"
      name   = "IA"
      mac    = "02:00:00:00:00:06"
      ip_emi = "10.30.6.1"
      prefix = "24"
      role   = "ia"
    }
    traffic = {
      ip     = "10.30.7.0/24"
      name   = "TRAFFIC"
      mac    = "02:00:00:00:00:07"
      ip_emi = "10.30.7.1"
      prefix = "24"
      role   = "traffic"
    }
    dmz-vpn = {
      ip     = "10.30.8.0/24"
      name   = "DMZ VPN"
      mac    = "02:00:00:00:00:08"
      ip_emi = "10.30.8.1"
      prefix = "24"
      role   = "dmz-vpn"
    }
    vpn-user = {
      ip     = "10.30.9.0/24"
      name   = "Pool VPN User"
      mac    = "02:00:00:00:00:09"
      ip_emi = "10.30.9.1"
      prefix = "24"
      role   = "vpn-user"
    }
    vpn-admin = {
      ip     = "10.30.10.0/24"
      name   = "Pool VPN Admin"
      mac    = "02:00:00:00:00:0a"
      ip_emi = "10.30.10.1"
      prefix = "24"
      role   = "vpn-admin"
    }
    vpn-peers = {
      ip     = "10.30.11.0/24"
      name   = "Pool VPN Site to Site"
      mac    = "02:00:00:00:00:0b"
      ip_emi = "10.30.11.1"
      prefix = "24"
      role   = "vpn-peers"
    }
    
  }

  # A creer en single server, tenants_per_host par hote avec une alpine par hote, ils ne doivent pas etre dupliques sur tous les hotes
  tenants = {
    for i in range(0, local.tenant_count) :
    "tenant${i}" => {
      ip     = "10.30.${20 + i}.0/24"
      name   = "TENANT-${i}"
      # 02:00:00:01:00:XX -> XX = numéro du tenant en hexa (01..14)
      mac    = format("02:00:00:01:00:%02x", i)
      ip_emi = "10.30.${20 + i}.1"
      prefix = "24"
      role   = "tenant${i}"
    }
  }

  # tenantN -> numero du noeud qui l'heberge (alpine + VM users sur le meme hote)
  tenant_nodes = {
    for i in range(0, local.tenant_count) :
    "tenant${i}" => floor(i / local.tenants_per_host)
  }

  all_vnets = merge(local.vnets, local.tenants)

  # IP de chaque alpine sur transit : .11, .12, .13 (noeud 0, 1, 2)
  alpine_ips = {
    for n in range(length(local.hosts_name)) :
    tostring(n) => cidrhost(local.vnets["transit"].ip, local.gateway_number + n + 1)
  }

  dhcp_vnets = {
    for k, v in local.all_vnets : k => v
    if startswith(v.role, "tenant") || v.role == "stockage" || v.role == "monitoring" || v.role == "backend" || v.role == "ia" || length(regexall("vpn", v.role)) > 0
  }

  # MAC unique de chaque routeur sur chaque vnet : on remplace le 5e octet de la
  # MAC du vnet par le numero de noeud (sinon 3 routeurs auraient la meme MAC
  # sur le meme vnet).
  router_macs = {
    for n in range(length(local.hosts_name)) : tostring(n) => {
      for k, v in local.vnets : k => join(":", concat(
        slice(split(":", v.mac), 0, 4),
        [format("%02x", n)],
        slice(split(":", v.mac), 5, 6)
      ))
    }
  }

  # Pools VPN : le serveur VPN (dans dmz-vpn) y place les clients
  vpn_pools = ["vpn-user", "vpn-admin", "vpn-peers"]

  # toutes les communications autorisees sans restriction de port
  # (l'acces a Internet, le ping des routeurs et les reponses DHCP sont geres a part, dans le playbook)
  links = concat(
    # gestion <-> tous les vnets
    [for k in keys(local.all_vnets) : { from = k, to = "gestion" } if k != "gestion"],
    [for k in keys(local.all_vnets) : { from = "gestion", to = k } if k != "gestion"],
    # tous les vnets -> services (DNS, DHCP, NetBox...)
    [for k in keys(local.all_vnets) : { from = k, to = "services" } if k != "services"],
    # users <-> pools VPN (pas la dmz vpn) ; jamais user <-> user
    [for t in keys(local.tenants) : { from = t, to = "vpn-user" }],
    [for t in keys(local.tenants) : { from = "vpn-user", to = t }],
    [for t in keys(local.tenants) : { from = t, to = "vpn-admin" }],
    [for t in keys(local.tenants) : { from = "vpn-admin", to = t }],
    [for t in keys(local.tenants) : { from = t, to = "vpn-peers" }],
    [for t in keys(local.tenants) : { from = "vpn-peers", to = t }],
    # la dmz vpn parle a ses pools
    [for p in local.vpn_pools : { from = "dmz-vpn", to = p }],
    # backend et ia <-> stockage
    [{ from = "stockage", to = "backend" }, { from = "backend", to = "stockage" }],
    [{ from = "ia", to = "stockage" }, { from = "stockage", to = "ia" }],
    # monitoring et traffic : en attente d'instructions, rien de plus
  )

  # pour chaque vnet : vnets joignables sans restriction de port
  allowed_links = {
    for k in keys(local.all_vnets) : k => distinct([for l in local.links : l.to if l.from == k])
  }

  # vnets dont les VM utilisent le script de failover (donc doivent pouvoir pinger les routeurs) :
  # tous les vnets d'infra sauf les pools VPN (ce sont des plages de clients, pas des VM)
  failover_vnets = [for k, v in local.vnets : k if !startswith(v.role, "vpn-")]

  # vnet sur lequel les pfSense synchronisent leurs etats (pfsync, multicast entre tous les routeurs)
  pfsync_vnet = "gestion"

  # Acces SSH de la machine qui lance Terraform vers le bastion (rebond), par mot de passe
  bastion_ssh_user = "debian"   # A ADAPTER : utilisateur du template Debian
}

data "xenorchestra_host" "hosts" {
  for_each = toset(local.hosts_name)
  name_label = each.value
}

locals {
  hosts_ids = [for name in local.hosts_name : data.xenorchestra_host.hosts[name].id]

  # LE bastion unique, sur emilia
  bastion_host = data.xenorchestra_host.hosts["emilia"].id
}

check "capacity" {
  assert {
    # 3e octet = 20 + i : on ne doit pas depasser 255
    condition     = 20 + local.tenant_count - 1 <= 255
    error_message = "Trop de tenants : le 3e octet depasse 255 (reduire tenants_per_host ou le nombre d'hotes)."
  }
  assert {
    # un pfSense (.1+) et une alpine (.11+) par hote dans la plage reservee
    condition     = length(local.hosts_name) <= local.gateway_number
    error_message = "Plus d'hotes que d'IP reservees aux routeurs (gateway_number)."
  }
}


# =========================================================================
# APPEL AUX MODULES
# =========================================================================

module vnets {
  source = "./modules/vnets"
  pool = data.xenorchestra_pool.pool.id
  vnets = { for k,v in local.vnets : k => { name = v.name } }
  internal_vnets = { for k,v in local.tenants : k => { name = v.name } }
  pif_ids = [ "eth0" ]
}

module bastion {
  source = "./modules/bastion"
  pool = data.xenorchestra_pool.pool.id
  host = local.bastion_host
  network_id = module.vnets.ids["gestion"]
  gateway_number = local.gateway_number
  gestion_cidr = local.vnets["gestion"].ip
  internal_cidr = local.internal_cidr
  # le navigateur (Pool-wide) atteint les VM users : tous les reseaux tenants, en TCP
  wan_access_cidrs = [for t in local.tenants : t.ip]
  router_gestion_macs = { for n, m in local.router_macs : n => m["gestion"] }
}

module routeur {
  source = "./modules/routeur"
  pool = data.xenorchestra_pool.pool.id
  hosts = local.hosts_ids
  network_ids = module.vnets.ids
  # pfSense : uniquement les vnets d'infra (les tenants sont routes par les alpines)
  vnets = local.vnets
  tenants = local.tenants
  tenant_nodes = local.tenant_nodes
  alpine_ips = local.alpine_ips
  router_macs = local.router_macs
  bastion_wan_ip = module.bastion.wan_ip
  bastion_gestion_ip = module.bastion.gestion_ip
  failover_vnets = local.failover_vnets
  pfsync_vnet = local.pfsync_vnet
  bastion_ssh_user = local.bastion_ssh_user
  bastion_ssh_password = var.bastion_ssh_password
  allowed_links = local.allowed_links
  dhcp_server_ips = local.dhcp_ips
  dns_server_ips = local.dns_ips
  # transit en plus : les alpines relaient le DHCP des tenants depuis ce vnet
  dhcp_vnets_keys = concat(keys(local.dhcp_vnets), ["transit"])
}

module alpine {
  source = "./modules/alpine"
  pool = data.xenorchestra_pool.pool.id
  hosts = local.hosts_ids
  tenants = local.tenants
  tenant_nodes = local.tenant_nodes
  tenant_network_ids = module.vnets.tenant_ids
  transit_network_id = module.vnets.ids["transit"]
  transit_cidr = local.vnets["transit"].ip
  alpine_ips = local.alpine_ips
  gateway_number = local.gateway_number
  dhcp_server_ips = local.dhcp_ips
}

module services {
  source = "./modules/services"
  pool = data.xenorchestra_pool.pool.id
  hosts = local.hosts_ids
  network_id = module.vnets.ids["services"]
  dhcp_vnets = local.dhcp_vnets
  all_vnets = local.all_vnets
  gateway_number = local.gateway_number
  gateways_cidr = local.vnets["services"].ip
  svc_net_ips = local.svc_net_ips
  netbox_superuser_password = var.netbox_superuser_password
  netbox_api_token = var.netbox_api_token
  kea_api_password = var.kea_api_password
}

# =========================================================================
# SORTIES
# =========================================================================

# Ou creer les VM users : sur l'hote de leur alpine, reseau = TENANT-n, passerelle = .1 (l'alpine)
output "tenant_placement" {
  value = {
    for k, v in local.tenants : k => {
      network = v.name
      cidr    = v.ip
      node    = local.tenant_nodes[k]
      host    = local.hosts_name[local.tenant_nodes[k]]
      gateway = v.ip_emi
    }
  }
}
