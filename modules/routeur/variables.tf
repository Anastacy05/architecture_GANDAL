variable pool { type = string }

variable hosts {
    type = list(string)
}

variable network_ids {
    type = map(string)
}

# vnets d'infra : ce sont les pattes des pfSense (gestion en premier, voir main.tf)
variable vnets {
    type = map(object({
        ip = string
        name = string
        mac = string
        ip_emi = string
        prefix = string
        role = string
    }))
}

# reseaux users : PAS de patte pfSense, routes statiques vers l'alpine de leur noeud
variable tenants {
    type = map(object({
        ip = string
        name = string
        mac = string
        ip_emi = string
        prefix = string
        role = string
    }))
}

# tenantN -> numero du noeud (donc de l'alpine) qui le route
variable tenant_nodes {
    type = map(number)
}

# numero de noeud -> IP de l'alpine sur transit
variable alpine_ips {
    type = map(string)
}

variable "router_macs" {
  type = map(map(string))
}

variable "bastion_wan_ip" {
  type = string
}

variable "bastion_ssh_user" { type = string }

variable "bastion_ssh_password" {
  type      = string
  sensitive = true
}

variable "allowed_links" {
  type = map(list(string))
}

variable "dhcp_server_ips" { type = list(string) }

variable "dns_server_ips" { type = list(string) }

variable "dhcp_vnets_keys" { type = list(string) }

# IP du bastion sur GESTION : passerelle par defaut des pfSense (il fait le NAT vers Internet)
variable "bastion_gestion_ip" {
  type = string
}

# vnets dont les VM utilisent le failover : les routeurs doivent y repondre au ping
variable "failover_vnets" {
  type = list(string)
}

# vnet de synchronisation pfsync
variable "pfsync_vnet" {
  type = string
}
