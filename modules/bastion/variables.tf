variable pool { type = string }

variable hosts { type = list(string) }

variable network_id { type = string }

variable gateway_number { type = number }

variable gateways_cidr { type = string }

variable internal_cidr { type = string }
variable "router_gateway_macs" {
  type = map(string)
}