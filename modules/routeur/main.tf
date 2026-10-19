terraform {
  required_providers {
    xenorchestra = {
      source  = "vatesfr/xenorchestra"
      version = "~> 0.29.0"
    }
  }
}


# =========================================================================
# RESSOURCES XCP-ng EXISTANTES
# =========================================================================

data "xenorchestra_template" "debian" {
    name_label = "PfSense-Template-Base"
    pool_id    = var.pool
}

data "xenorchestra_sr" "sr_local" {
    name_label = "Local Storage"
    pool_id    = var.pool
}


# =========================================================================
# AJOUT DU RESEAU DES HOTES
# =========================================================================

locals {
    pool_network = {
        ip = "192.168.122.10/24"
        name = "Pool-wide network 0"
    }
    networks = merge(local.pool_network, var.vnets)
}

data "xenorchestra_network" "networks_xen" {
  for_each   = local.networks
  name_label = each.value.name
}


# =========================================================================
# VM ROUTEUR
# =========================================================================

resource "xenorchestra_vm" "vm_routeur" {

  name_label = "Pfsense"

  name_description = "VM Pfsense Routeur créée avec Terraform"

  template = data.xenorchestra_template.debian.id

  cpus       = 2
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"

  # -----------------------------------------------------------------------
  # RÉSEAU & CLOUD-INIT
  # -----------------------------------------------------------------------

  dynamic network {
      for_each    = data.xenorchestra_network.networks_xen
      content {
      	network_id  = each.value.id
      }
  }

  cloud_config = <<EOF
      #cloud-config

      hostname: PfSense
      manage_etc_hosts: true
  EOF
  #les regles de traffic a inserer ici, les relais pour le dns et le dhcp, aucune communication inter-Vnet sauf vers les services

  cloud_network_config = <<EOF
      network
        version: 1
        config:
        - type: physical
          name: enX0
          subnets:
            - type: static
              address: ${local.networks[0].ip}
              gateway: 192.168.122.1/24
      %{for index, vnet in local.networks}
        %{if index!=0}
            - type: physical
            name: enX${index}
            subnets:
                - type: static
                address: ${vnet.ip}
        %{endif}
      %{endfor}
  EOF	

  # -----------------------------------------------------------------------
  # DISQUE
  # -----------------------------------------------------------------------

  disk {
    name_label = "PfSense-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 20 * 1024 * 1024 * 1024
  }
  
}


# =========================================================================
# SORTIE
# =========================================================================

output "id" {
    value = xenorchestra_vm.vm_routeur.id
}