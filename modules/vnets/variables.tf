variable pool { type = string }

variable vnets {
    type = map(object({
        name = string
    }))
} 