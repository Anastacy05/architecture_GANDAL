variable pool { type = string }

variable vnets {
    type = map(object({
        ip = string
        name = string
        mac = string
        ip_y = string
        prefix = string
        role = string
    }))
} 