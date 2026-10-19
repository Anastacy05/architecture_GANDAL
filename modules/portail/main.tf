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
  name_label = "Service-Template-Base"
  pool_id    = var.pool
}

data "xenorchestra_sr" "sr_local" {
  name_label = "Local Storage"
  pool_id    = var.pool
}

data "xenorchestra_network" "vnet_dmz" {
  name_label = "Vnet-DMZ"
}

data "xenorchestra_network" "vnet_vpn" {
  name_label = "Vnet-VPN"
}

data "xenorchestra_network" "pool_network" {
  name_label = "Pool-wide network 0"
}


# =========================================================================
# VMs
# =========================================================================

resource "xenorchestra_vm" "vm_portail" {

  name_label = "VM-Portail"

  name_description = "VM Portail créée avec Terraform"

  template = data.xenorchestra_template.debian.id

  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"

  # -----------------------------------------------------------------------
  # RÉSEAU & CLOUD-INIT
  # -----------------------------------------------------------------------

  network {
      network_id  = data.xenorchestra_network.pool_network.id
  }
  network {
      network_id  = data.xenorchestra_network.vnet_vpn.id
  }
  network {
      network_id  = data.xenorchestra_network.vnet_dmz.id
  }

  cloud_config = <<EOF
      #cloud-config

      hostname: VM-Portail
      manage_etc_hosts: true
  EOF
  # les configurations vpn et dnat pour les services de la dmz a inserer ici

  cloud_network_config = <<EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 192.168.122.11/24
            gateway: 192.168.122.1/24
      - type: physical
        name: enX1
        subnets:
          - type: static
            address: 10.0.60.2/24
            gateway: 10.0.60.1/24
      - type: physical
        name: enX2
        subnets:
          - type: static
            address: 10.0.50.2/24
            gateway: 10.0.50.1/24
  EOF	

  # -----------------------------------------------------------------------
  # DISQUE
  # -----------------------------------------------------------------------

  disk {
    name_label = "VM-Portail-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}


# =========================================================================
# SORTIE
# =========================================================================

output "id" {
  value = xenorchestra_vm.vm_portail.id
}