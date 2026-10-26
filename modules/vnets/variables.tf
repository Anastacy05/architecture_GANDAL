variable pool { type = string }

variable vnets {
    type = map(object({
        name = string
    }))
} 

variable "pif_ids" {
  description = "PIF sur laquelle passent les tunnels (physique, VLAN ou bond, avec une IP). Une par pool."
  type        = list(string)
}
