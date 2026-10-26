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

resource "terraform_data" "private_network" {
  for_each = var.vnets
  triggers_replace = {
    name = each.value.name
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      if xo-cli list-objects type=network name_label="${each.value.name}" | grep -qw -- "${each.value.name}"; then
        echo "Réseau ${each.value.name} déjà présent, rien à faire"
        exit 0
      fi

      xo-cli sdnController.createPrivateNetwork \
        poolIds=json:'["${var.pool}"]' \
        pifIds=json:'${jsonencode(var.pif_ids)}' \
        name="${each.value.name}" \
        description="${each.value.name} (géré par Terraform)" \
        encapsulation=vxlan \
        encrypted=false \
        mtu=1500
    EOT
  }

}


# =========================================================================
# SORTIE
# =========================================================================

data "xenorchestra_network" "vnet" {
  for_each   = var.vnets
  name_label = each.value.name
  pool_id    = var.pool

  depends_on = [terraform_data.private_network]
}

output "ids" {
    value = { for k, v in data.xenorchestra_network.vnet : k => v.id }
}