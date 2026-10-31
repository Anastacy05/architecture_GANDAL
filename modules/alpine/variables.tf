variable pool { type = string }

variable hosts { type = list(string) }

# Template Linux existant (Debian avec cloud-init + ssh uniquement) : les paquets sont installes par apt au 1er boot
variable template_name {
  type    = string
  default = "Debian-Template-Base"
}

# reseaux users (tous) ; chaque alpine ne prend que ceux de son noeud
variable tenants {
  type = map(object({
    ip     = string
    name   = string
    mac    = string
    ip_emi = string
    prefix = string
    role   = string
  }))
}

# tenantN -> numero du noeud
variable tenant_nodes { type = map(number) }

# tenantN -> id du reseau XCP-ng
#variable tenant_network_ids { type = map(string) }

variable transit_network_id { type = string }

variable transit_cidr { type = string }

# numero de noeud -> IP de l'alpine sur transit
variable alpine_ips { type = map(string) }

# .1 a .gateway_number : pfSense (un par noeud) = candidats du failover
variable gateway_number { type = number }

# Serveurs DHCP (Kea) vers lesquels l'alpine relaie le DHCP des reseaux users
variable dhcp_server_ips { type = list(string) }

# Route geree par le failover : "default" (tout passe par pfSense, y compris les tenants des autres noeuds)
variable route_dest {
  type    = string
  default = "default"
}

variable cpus {
  type    = number
  default = 1
}

variable memory_max {
  type    = number
  default = 1073741824 # 1 Go : une alpine porte tenants_per_host + 1 interfaces
}

variable disk_size {
  type    = number
  default = 10737418240 # 10 Go, comme les autres VM Debian
}
