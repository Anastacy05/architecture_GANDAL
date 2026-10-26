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
    url      = "ws://127.0.0.1:80"
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
# LISTES DES RÉSEAUX
# =========================================================================

locals {

  hosts_name = [ "emilia", "ram", "rem" ]

  dns_ips = ["10.0.0.14", "10.0.0.15", "10.0.0.16"]
  dhcp_ips = ["10.0.0.12", "10.0.0.13"]
  vnets = {
    gateway = {
      ip     = "10.0.0.0/24"
      name   = "Vnet-Gateway"
      mac    = "02:00:00:00:00:00"
      ip_emi = "10.0.0.1"
      prefix = "24"
      role   = "gateway"
    }
    services = {
      ip     = "10.0.10.0/24"
      name   = "Vnet-Services"
      mac    = "02:00:00:00:00:01"
      ip_emi = "10.0.10.1"
      prefix = "24"
      role   = "services"
    }
    vpn = {
      ip     = "10.0.20.0/24"
      name   = "Vnet-VPN"
      mac    = "02:00:00:00:00:02"
      ip_emi = "10.0.20.1"
      prefix = "24"
      role   = "vpn"
    }
    dmz = {
      ip     = "10.0.30.0/24"
      name   = "Vnet-DMZ"
      mac    = "02:00:00:00:00:03"
      ip_emi = "10.0.30.1"
      prefix = "24"
      role   = "dmz"
    }
    management = {
      ip     = "10.0.40.0/24"
      name   = "Vnet-Management"
      mac    = "02:00:00:00:00:04"
      ip_emi = "10.0.40.1"
      prefix = "24"
      role   = "management"
    }
    observation = {
      ip     = "10.0.50.0/24"
      name   = "Vnet-Observation"
      mac    = "02:00:00:00:00:05"
      ip_emi = "10.0.50.1"
      prefix = "24"
      role   = "observation"
    }
    stockage = {
      ip     = "10.0.60.0/24"
      name   = "Vnet-Stockage"
      mac    = "02:00:00:00:00:06"
      ip_emi = "10.0.60.1"
      prefix = "24"
      role   = "stockage"
    }
    backend = {
      ip     = "10.0.70.0/24"
      name   = "Vnet-Backend"
      mac    = "02:00:00:00:00:07"
      ip_emi = "10.0.70.1"
      prefix = "24"
      role   = "backend"
    }
    
  }

  tenants = {
    for i in range(0, 20) :
    "tenant${i}" => {
      ip     = "10.0.${100 + i}.0/24"
      name   = "Vnet-Tenant-${i}"
      # 02:00:00:01:00:XX -> XX = numéro du tenant en hexa (01..14)
      mac    = format("02:00:00:01:00:%02x", i)
      ip_emi = "10.0.${100+i}.1"
      prefix = "24"
      role   = "tenant${i}"
    }
  }

  all_vnets = merge(local.vnets, local.tenants)

  # MAC unique de chaque routeur sur chaque vnet : on remplace le 5e octet de la
  # MAC du vnet par le numero de noeud (sinon 3 routeurs auraient la meme MAC
  # sur le meme vnet).
  router_macs = {
    for n in range(length(local.hosts_name)) : tostring(n) => {
      for k, v in local.all_vnets : k => join(":", concat(
        slice(split(":", v.mac), 0, 4),
        [format("%02x", n)],
        slice(split(":", v.mac), 5, 6)
      ))
    }
  }

  # Acces SSH de la machine qui lance Terraform vers les bastions (rebond)
  bastion_ssh_user = "debian"                    # A ADAPTER : utilisateur du template Debian
  bastion_ssh_key  = pathexpand("~/.ssh/id_ed25519") # A ADAPTER : cle autorisee sur les bastions
}

data "xenorchestra_host" "hosts" {
  for_each = toset(local.hosts_name)
  name_label = each.value
}

locals {
  hosts_ids = [for name in local.hosts_name : data.xenorchestra_host.hosts[name].id]
}


# =========================================================================
# APPEL AUX MODULES
# =========================================================================

module vnets {
  source = "./modules/vnets"
  pool = data.xenorchestra_pool.pool.id
  vnets = { for k,v in local.all_vnets : k => { name = v.name } }
}

module bastion {
  source = "./modules/bastion"
  pool = data.xenorchestra_pool.pool.id
  hosts = local.hosts_ids
  network_id = module.vnets.ids["gateway"]
  gateway_number = 10
  gateways_cidr = local.all_vnets["gateway"].ip
  internal_cidr = "10.0.0.0/16"
  router_gateway_macs = { for n, m in local.router_macs : n => m["gateway"] }
}

module routeur {
  source = "./modules/routeur"
  pool = data.xenorchestra_pool.pool.id
  hosts = local.hosts_ids
  network_ids = module.vnets.ids
  vnets = local.all_vnets
  router_macs = local.router_macs
  bastion_wan_ips = module.bastion.wan_ips
  bastion_ssh_user = local.bastion_ssh_user
  bastion_ssh_key = local.bastion_ssh_key
  dhcp_server_ips = local.dhcp_ips
}

module services {
  source = "./modules/services"
  pool = data.xenorchestra_pool.pool.id
  hosts = local.hosts_ids
  network_id = module.vnets.ids["services"]
  dhcp_vnets = {
    for k, v in local.all_vnets : k => v
    if startswith(v.role, "tenant") || v.role == "vpn" || v.role == "stockage" || v.role == "backend"
  }
  all_vnets = local.all_vnets
}