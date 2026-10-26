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
# RESEAUX
# =========================================================================

locals {
  pool_network = {
    ip     = "192.168.122.0/24"
    name   = "Pool-wide network 0"
    mac    = "02:00:00:00:01:01"
    ip_y   = "192.168.122.10"
    prefix = "24"
    role   = "wan"
  }

  # IP WAN récupérée après que expected_ip_cidr ait attendu
  wan_ip = [
    for ip in xenorchestra_vm.vm_routeur.ipv4_addresses :
    ip if startswith(ip, "192.168.122.")
  ][0]
}

data "xenorchestra_network" "network_xen" {
  name_label = local.pool_network.name
}

data "xenorchestra_network" "networks_xen" {
  for_each   = var.vnets
  name_label = each.value.name
}

# =========================================================================
# VM ROUTEUR
# =========================================================================

resource "xenorchestra_vm" "vm_routeur" {
  for_each = var.hosts
  name_label       = "Pfsense-${index(var.hosts, each.value)}"
  name_description = "VM RouteurPfsense créée avec Terraform"
  host = each.value

  template          = data.xenorchestra_template.debian.id
  cpus              = 2
  memory_max        = 1073741824
  hvm_boot_firmware = "bios"

  # --- VIF WAN (obligatoire : expected_ip_cidr) ---
  network {
    network_id       = data.xenorchestra_network.network_xen.id
    mac_address      = local.pool_network.mac
    expected_ip_cidr = local.pool_network.ip
  }

  dynamic "network" {
    for_each = var.vnets
    content {
      network_id  = var.network_ids[each.value.index]
      mac_address = each.value.mac
    }
  }

  disk {
    name_label = "PfSense-${index(var.hosts, each.value)}-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 20 * 1024 * 1024 * 1024
  }
}

# =========================================================================
# PROVISIONING ANSIBLE
# =========================================================================

resource "terraform_data" "ansible_provisioning" {
  depends_on = [xenorchestra_vm.vm_routeur]

  triggers_replace = {
    vm_ip = local.wan_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "[pfsense]" > inventory.ini
      echo "ansible_host=${local.wan_ip} ansible_user=admin ansible_ssh_pass=admin ansible_ssh_common_args='-o StrictHostKeyChecking=no'" >> inventory.ini

      ansible-playbook -i inventory.ini playbook.yml \
        --extra-vars 'vnet_configs_json=${jsonencode(var.vnets)}' \
        --extra-vars 'dhcp_server_ip=10.0.10.12,10.0.10.13'
    EOT

    working_dir = "${path.module}/ansible"
  }
}

# =========================================================================
# SORTIES
# =========================================================================

output "id" {
  value = xenorchestra_vm.vm_routeur.id
}

output "wan_ip" {
  value = local.wan_ip
}