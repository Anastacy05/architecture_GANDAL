variable pool { type = string }

variable hosts {
    type = list(string)
}

variable network_ids {
    type = list(string)
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