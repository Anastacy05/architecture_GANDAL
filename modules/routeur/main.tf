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
# LOCALS
# =========================================================================

locals {
  nodes = { for i, h in var.hosts : tostring(i) => h }

  # Tous les vnets sauf gateway (celui-ci est declaré en premier, à parti)
  other_vnets = { for k, v in var.vnets : k => v if k != "gateway" }

  # Config de chaque routeur, passee a Ansible : IP = .(noeud+1) sur CHAQUE vnet
  router_configs = {
    for n, _ in local.nodes : n => [
      for k, v in var.vnets : {
        name   = v.name
        role   = v.role
        mac    = var.router_macs[n][k]
        ip     = cidrhost(v.ip, tonumber(n) + 1)
        prefix = v.prefix
        net    = v.ip
        allow_to = [for d in var.allowed_links[k] : var.vnets[d].ip]
        dns  = k != "services"
        dhcp = contains(var.dhcp_vnets_keys, k)
      }
    ]
  }

  # IP du routeur sur le vnet gateway : c'est par la que Ansible le joint
  gateway_ips = {
    for n, _ in local.nodes : n => cidrhost(var.vnets["gateway"].ip, tonumber(n) + 1)
  }
}


# =========================================================================
# VM ROUTEUR
# =========================================================================

resource "xenorchestra_vm" "vm_routeur" {
  for_each = local.nodes
  name_label       = "Pfsense-${each.key}"
  name_description = "VM RouteurPfsense créée avec Terraform"
  host = each.value

  template          = data.xenorchestra_template.debian.id
  cpus              = 2
  memory_max        = 1073741824
  hvm_boot_firmware = "bios"

  network {
    network_id  = var.network_ids["gateway"]
    mac_address = var.router_macs[each.key]["gateway"]
  }
  dynamic "network" {
    for_each = local.other_vnets
    iterator = vn
    content {
      network_id  = var.network_ids[vn.key]
      mac_address = var.router_macs[each.key][vn.key]
    }
  }

  disk {
    name_label = "PfSense-${each.key}-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 20 * 1024 * 1024 * 1024
  }
}

# =========================================================================
# PROVISIONING ANSIBLE
# =========================================================================

resource "terraform_data" "ansible_provisioning" {
  for_each   = local.nodes
  depends_on = [xenorchestra_vm.vm_routeur]

  triggers_replace = {
    vm      = xenorchestra_vm.vm_routeur[each.key].id
    configs = sha1(jsonencode(local.router_configs[each.key]))
    dhcp    = join(",", var.dhcp_server_ips)
    dns     = join(",", var.dns_server_ips)
  }

  provisioner "local-exec" {
    # Un inventaire par noeud : les 3 runs tournent en parallele dans le meme dossier
    command = <<-EOT
      printf '[pfsense]\nrouter ansible_host=%s ansible_user=admin ansible_ssh_pass=admin ansible_ssh_common_args=%s\n' \
        "$ROUTER_IP" "'$SSH_ARGS'" > inventory-${each.key}.ini
      ansible-playbook -i inventory-${each.key}.ini playbook.yml
    EOT

    working_dir = "${path.module}/ansible"

    environment = {
      ROUTER_IP         = local.gateway_ips[each.key]
      VNET_CONFIGS_JSON = jsonencode(local.router_configs[each.key])
      DHCP_SERVER_IP    = join(",", var.dhcp_server_ips)
      DNS_SERVERS       = join(",", var.dns_server_ips)
      SSH_ARGS = join(" ", [
        "-o StrictHostKeyChecking=no",
        "-o UserKnownHostsFile=/dev/null",
        "-o ProxyCommand=\"ssh -W %h:%p -q -i ${var.bastion_ssh_key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${var.bastion_ssh_user}@${var.bastion_wan_ips[each.key]}\"",
      ])
    }
  }
}

# =========================================================================
# SORTIES
# =========================================================================

output "ids" {
  value = { for k, vm in xenorchestra_vm.vm_routeur : k => vm.id }
}

output "gateway_ips" {
  value = local.gateway_ips
}