variable pool { type = string }

variable hosts { type = list(string) }

# vnet SERVICES
variable network_id { type = string }

# vnets pour lesquels Kea sert des baux (infra + tenants)
variable dhcp_vnets {
  type = map(object({
    ip     = string
    name   = string
    mac    = string
    ip_emi = string
    prefix = string
    role   = string
  }))
}

# tous les vnets : sources autorisees a interroger bind
variable all_vnets {
  type = map(object({
    ip     = string
    name   = string
    mac    = string
    ip_emi = string
    prefix = string
    role   = string
  }))
}

variable gateway_number { type = number }

# CIDR du vnet SERVICES (les pfSense y sont en .1, .2, ... ; les svc-net apres .gateway_number)
variable gateways_cidr { type = string }

# IP de chaque svc-net sur SERVICES, dans l'ordre des hotes (svc-net-0 sur le 1er hote...)
variable svc_net_ips { type = list(string) }

variable domain {
  type    = string
  default = "gandal.internal"
}

# Resolveurs externes : forwarders de bind ET resolveurs de la VM au 1er boot (avant que bind soit demarre)
variable forwarders {
  type    = list(string)
  default = ["8.8.8.8", "1.1.1.1"]
}

# --- Secrets : A CHANGER (TF_VAR_...) -----------------------------------------
variable netbox_superuser_password {
  type      = string
  sensitive = true
  default   = "ChangeMeInProduction!"
}

variable netbox_api_token {
  type      = string
  sensitive = true
  default   = "0123456789abcdef0123456789abcdef01234567"
}

variable kea_api_password {
  type      = string
  sensitive = true
  default   = "ChangeMeKeaPass"
}

# --- Kea ----------------------------------------------------------------------
# Port HA entre les svc-net (listener dedie de kea-dhcp4). L'API (Control Agent) reste sur 8000.
variable kea_ha_port {
  type    = number
  default = 8001
}

variable cpus {
  type    = number
  default = 2
}

variable memory_max {
  type    = number
  default = 4294967296 # 4 Go : docker + NetBox + postgres + redis + bind + kea
}

variable disk_size {
  type    = number
  default = 32212254720 # 30 Go : images docker NetBox
}
