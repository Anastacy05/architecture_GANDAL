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

  hosts_name = [ emilia, ram, rem ]
  vnets = {
    gateway = {
      ip     = "10.0.0.0/24"
      name   = "Vnet-Services"
      mac    = "02:00:00:00:00:00"
      ip_emi = "10.0.0.1"
      prefix = "24"
      role   = "services"
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
}

data "xenorchestra_host" "hosts" {
  for_each = local.hosts_name
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
}

module routeur {
  source = "./modules/routeur"
  pool = data.xenorchestra_pool.pool.id
  hosts = local.hosts_ids
  network_ids = module.vnets.ids
  vnets = local.all_vnets
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