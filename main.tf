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
  vnets = {
    services = {
      ip   = "10.0.20.1/24"
      name = "Vnet-Services"
    }
    management = {
      ip   = "10.0.30.1/24"
      name = "Vnet-Management"
    }
    observation = {
      ip   = "10.0.40.1/24"
      name = "Vnet-Observation"
    }
    dmz = {
      ip   = "10.0.50.1/24"
      name = "Vnet-DMZ"
    }
    vpn = {
      ip   = "10.0.60.1/24"
      name = "Vnet-VPN"
    }
  }

  tenants = {
    for i in range(1, 51) :
    "tenant${i}" => {
      ip   = "10.0.${100 + i}.1/24"
      name = "Vnet-Tenant-${i}"
    }
  }

  all_vnets = merge(local.vnets, local.tenants)
}


# =========================================================================
# APPEL AUX MODULES
# =========================================================================

module vnets {
  source = "./modules/vnets"
  pool = data.xenorchestra_pool.pool.id
  vnets = { for k,v in local.all_vnets : k => { name = v.name } }
}

module routeur {
  source = "./modules/routeur"
  pool = data.xenorchestra_pool.pool.id
  vnets = local.all_vnets
}

module services {
  source = "./modules/services"
  pool = data.xenorchestra_pool.pool.id
}

module portail {
  source = "./modules/portail"
  pool = data.xenorchestra_pool.pool.id
}