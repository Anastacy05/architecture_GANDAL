variable pool {
  type = string
}

variable hosts {
    type = list(string)
}

variable network_id {
    type = string
}

variable dhcp_vnets {
    type = map(object({
        ip = string
        name = string
        mac = string
        ip_emi = string
        prefix = string
        role = string
    }))
} 

variable all_vnets {
    type = map(object({
        ip = string
        name = string
        mac = string
        ip_emi = string
        prefix = string
        role = string
    }))
} 

variable gateway_number { type = number }

variable gateways_cidr { type = string }