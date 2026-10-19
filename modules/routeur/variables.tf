variable pool { type = string }

variable vnets {
    type = map(object({
        ip = string
        name = string
    }))
} 