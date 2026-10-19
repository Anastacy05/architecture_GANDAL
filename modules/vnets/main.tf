terraform {
  required_providers {
    xenorchestra = {
      source  = "vatesfr/xenorchestra"
      version = "~> 0.29.0"
    }
  }
}


# =========================================================================
# CREATION DES RESEAUX
# =========================================================================

resource "xenorchestra_network" "vnet" {
    for_each = var.vnets
    pool_id = var.pool
    name_label = each.value.name
}


# =========================================================================
# SORTIE
# =========================================================================

output "ids" {
    value = { for k, v in xenorchestra_network.vnet : k => v.id }
}