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

data "xenorchestra_network" "vnet_service" {
  name_label = "Vnet-Services"
}

data "xenorchestra_network" "vnet_dmz" {
  name_label = "Vnet-DMZ"
}


# =========================================================================
# VMs
# =========================================================================


resource "xenorchestra_vm" "vm_dns" {

  name_label = "VM-DNS"

  name_description = "VM DNS créée avec Terraform"

  template = data.xenorchestra_template.debian.id

  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"

  # -----------------------------------------------------------------------
  # RÉSEAU & CLOUD-INIT
  # -----------------------------------------------------------------------

  network {
      network_id  = data.xenorchestra_network.vnet_service.id
  }

  cloud_config = <<EOF
      #cloud-config

      hostname: VM-DNS
      manage_etc_hosts: true
  EOF
  # les configurations dns a inserer ici

  cloud_network_config = <<EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.20.2/24
            gateway: 10.0.20.1/24
  EOF	

  # -----------------------------------------------------------------------
  # DISQUE
  # -----------------------------------------------------------------------

  disk {
    name_label = "VM-DNS-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}


resource "xenorchestra_vm" "vm_dhcp" {

  name_label = "VM-DHCP"

  name_description = "VM DHCP créée avec Terraform"

  template = data.xenorchestra_template.debian.id

  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"

  # -----------------------------------------------------------------------
  # RÉSEAU & CLOUD-INIT
  # -----------------------------------------------------------------------

  network {
      network_id  = data.xenorchestra_network.vnet_service.id
  }

  cloud_config = <<EOF
      #cloud-config

      hostname: VM-DNS
      manage_etc_hosts: true
  EOF
  # les configurations dhcp a inserer ici

  cloud_network_config = <<EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.20.3/24
            gateway: 10.0.20.1/24
  EOF	

  # -----------------------------------------------------------------------
  # DISQUE
  # -----------------------------------------------------------------------

  disk {
    name_label = "VM-DNS-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}


resource "xenorchestra_vm" "vm_netbox" {

  name_label = "VM-NetBox"

  name_description = "VM NetBox créée avec Terraform"

  template = data.xenorchestra_template.debian.id

  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"

  # -----------------------------------------------------------------------
  # RÉSEAU & CLOUD-INIT
  # -----------------------------------------------------------------------

  network {
      network_id  = data.xenorchestra_network.vnet_service.id
  }

  cloud_config = <<EOF
      #cloud-config

      hostname: VM-NetBox
      manage_etc_hosts: true
  EOF
  # les configurations netbox a inserer ici

  cloud_network_config = <<EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.20.4/24
            gateway: 10.0.20.1/24
  EOF	

  # -----------------------------------------------------------------------
  # DISQUE
  # -----------------------------------------------------------------------

  disk {
    name_label = "VM-NetBox-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}

resource "xenorchestra_vm" "vm_keycloak" {

  name_label = "VM-KeyCloak"

  name_description = "VM KeyCloak créée avec Terraform"

  template = data.xenorchestra_template.debian.id

  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"

  # -----------------------------------------------------------------------
  # RÉSEAU & CLOUD-INIT
  # -----------------------------------------------------------------------

  network {
      network_id  = data.xenorchestra_network.vnet_service.id
  }

  cloud_config = <<EOF
      #cloud-config

      hostname: VM-KeyCloak
      manage_etc_hosts: true
  EOF
  # les configurations keycloak a inserer ici

  cloud_network_config = <<EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.20.5/24
            gateway: 10.0.20.1/24
  EOF	

  # -----------------------------------------------------------------------
  # DISQUE
  # -----------------------------------------------------------------------

  disk {
    name_label = "VM-KeyCloak-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}

resource "xenorchestra_vm" "vm_mail" {

  name_label = "VM-Mail"

  name_description = "VM Mail créée avec Terraform"

  template = data.xenorchestra_template.debian.id

  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"

  # -----------------------------------------------------------------------
  # RÉSEAU & CLOUD-INIT
  # -----------------------------------------------------------------------

  network {
      network_id  = data.xenorchestra_network.vnet_dmz.id
  }

  cloud_config = <<EOF
      #cloud-config

      hostname: VM-Mail
      manage_etc_hosts: true
  EOF
  # les configurations pour qu'il recoive les redirections du portail

  cloud_network_config = <<EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.50.3/24
            gateway: 10.0.20.1/24
  EOF	

  # -----------------------------------------------------------------------
  # DISQUE
  # -----------------------------------------------------------------------

  disk {
    name_label = "VM-Mail-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}


# =========================================================================
# SORTIE
# =========================================================================

output "dns_id" {
    value = xenorchestra_vm.vm_dns.id
}

output "dhcp_id" {
    value = xenorchestra_vm.vm_dhcp.id
}

output "netbox_id" {
    value = xenorchestra_vm.vm_netbox.id
}

output "keycloak_id" {
    value = xenorchestra_vm.vm_keycloak.id
}

output "mail_id" {
    value = xenorchestra_vm.vm_mail.id
}