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
      ip     = "10.0.20.0/24"
      name   = "Vnet-Services"
      mac    = "02:00:00:00:00:01"
      ip_y   = "10.0.20.1"
      prefix = "24"
      role   = "services"
    }
    management = {
      ip     = "10.0.30.0/24"
      name   = "Vnet-Management"
      mac    = "02:00:00:00:00:02"
      ip_y   = "10.0.30.1"
      prefix = "24"
      role   = "management"
    }
    observation = {
      ip     = "10.0.40.0/24"
      name   = "Vnet-Observation"
      mac    = "02:00:00:00:00:03"
      ip_y   = "10.0.40.1"
      prefix = "24"
      role   = "observation"
    }
    dmz = {
      ip     = "10.0.50.0/24"
      name   = "Vnet-DMZ"
      mac    = "02:00:00:00:00:04"
      ip_y   = "10.0.50.1"
      prefix = "24"
      role   = "dmz"
    }
    vpn = {
      ip     = "10.0.60.0/24"
      name   = "Vnet-VPN"
      mac    = "02:00:00:00:00:05"
      ip_y   = "10.0.60.1"
      prefix = "24"
      role   = "vpn"
    }
  }

  tenants = {
    for i in range(1, 21) :
    "tenant${i}" => {
      ip     = "10.0.${100 + i}.0/24"
      name   = "Vnet-Tenant-${i}"
      # 02:00:00:01:00:XX -> XX = numéro du tenant en hexa (01..14)
      mac    = format("02:00:00:01:00:%02x", i)
      ip_y   = "10.0.${100 + i}.1"
      prefix = "24"
      role   = "tenant${i}"
    }
  }

  # Fusion propre pour Terraform
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
  dhcp_vnets = {
    for k, v in local.all_vnets : k => v
    if startswith(v.role, "tenant") || v.role == "vpn"
  }
  all_vnets = local.all_vnets
}

module portail {
  source = "./modules/portail"
  pool = data.xenorchestra_pool.pool.id
}