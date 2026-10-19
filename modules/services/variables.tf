variable pool {
  type = string
}

variable dhcp_vnets {
    type = map(object({
        ip = string
        name = string
        mac = string
        ip_y = string
        prefix = string
        role = string
    }))
} 

variable all_vnets {
    type = map(object({
        ip = string
        name = string
        mac = string
        ip_y = string
        prefix = string
        role = string
    }))
} 