variable pool { type = string }

variable hosts {
    type = list(string)
}

variable network_ids {
    type = map(string)
}
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

variable "router_macs" {
  type = map(map(string))
}

variable "bastion_wan_ips" {
  type = map(string)
}

variable "bastion_ssh_user" { type = string }
variable "bastion_ssh_key" { type = string }

variable "allowed_links" {
  type = map(list(string))
}

variable "dhcp_server_ips" { type = list(string) }

variable "dns_server_ips" { type = list(string) }

variable "dhcp_vnets_keys" { type = list(string) }