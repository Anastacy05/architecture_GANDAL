variable pool { type = string }

# Hote du bastion unique (emilia)
variable host { 
  type = string
  default = "emilia" 
}

# Reseau GESTION
variable network_id { type = string }

variable gateway_number { type = number }

variable gestion_cidr { type = string }

variable internal_cidr { type = string }

# MAC de chaque routeur pfSense sur GESTION (cle = numero de noeud)
variable "router_gestion_macs" {
  type = map(string)
}

# Reseaux internes joignables depuis le Pool-wide (navigateur vers les VM users, sans SSH).
# Le bastion les traduit (masquerade) : les VM voient l'IP du bastion sur gestion.
variable "wan_access_cidrs" {
  type    = list(string)
  default = []
}

# Ports TCP de destination ouverts vers ces reseaux (syntaxe nftables : "1-65535" ou "{ 80, 443, 8000-8999 }")
variable "wan_access_dports" {
  type    = string
  default = "1-65535"
}
