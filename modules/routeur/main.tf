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

  infra_keys  = keys(var.vnets)
  tenant_keys = keys(var.tenants)

  # Tous les vnets d'infra sauf gestion (declare en premier : c'est la 1re patte, celle qui
  # obtient son IP du DHCP du bastion unique au premier demarrage)
  other_vnets = { for k, v in var.vnets : k => v if k != "gestion" }

  # Config de chaque routeur, passee a Ansible : IP = .(noeud+1) sur CHAQUE vnet d'infra
  router_configs = {
    for n, _ in local.nodes : n => [
      for k, v in var.vnets : {
        name   = v.name
        role   = v.role
        mac    = var.router_macs[n][k]
        ip     = cidrhost(v.ip, tonumber(n) + 1)
        prefix = v.prefix
        net    = v.ip
        # destinations d'infra : une regle par reseau
        allow_to = [for d in var.allowed_links[k] : var.vnets[d].ip if contains(local.infra_keys, d)]
        # destinations tenants : une seule regle vers l'alias TENANT_NETS
        allow_tenants = anytrue([for d in var.allowed_links[k] : contains(local.tenant_keys, d)])
        # les VM de ce vnet utilisent le failover : le routeur doit repondre au ping
        ping = contains(var.failover_vnets, k)
        dhcp = contains(var.dhcp_vnets_keys, k)
      }
    ]
  }

  # Cote tenants : un pfSense recoit leur trafic sur l'interface TRANSIT (source = IP du tenant).
  # Les flux autorises sont ceux de la matrice (identiques pour tous les tenants -> union).
  tenant_allowed_to = distinct(flatten([
    for t in local.tenant_keys : [
      for d in var.allowed_links[t] : var.vnets[d].ip if contains(local.infra_keys, d)
    ]
  ]))

  # Routes statiques : chaque tenant est joignable UNIQUEMENT via l'alpine de son noeud.
  # Cette config est identique sur tous les pfSense (chaque pfSense route tous les tenants).
  tenant_config = {
    transit_iface = var.vnets["transit"].name
    nets          = [for k in local.tenant_keys : var.tenants[k].ip]
    allowed_to    = local.tenant_allowed_to
    gateways = [
      for n, ip in var.alpine_ips : {
        name = "ALPINE_${n}"
        ip   = ip
      }
    ]
    routes = [
      for k in local.tenant_keys : {
        name    = var.tenants[k].name
        network = var.tenants[k].ip
        gateway = "ALPINE_${var.tenant_nodes[k]}"
      }
    ]
  }

  # Config commune a tous les routeurs : pfsync, passerelle par defaut (bastion)
  system_config = {
    pfsync_iface  = var.vnets[var.pfsync_vnet].name
    gestion_iface = var.vnets["gestion"].name
    bastion_ip    = var.bastion_gestion_ip
  }

  # IP du routeur sur GESTION : c'est par la que Ansible le joint (via le bastion unique)
  gestion_ips = {
    for n, _ in local.nodes : n => cidrhost(var.vnets["gestion"].ip, tonumber(n) + 1)
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

  # 1re patte = GESTION : DHCP du bastion d'emilia, puis joignable par Ansible
  network {
    network_id  = var.network_ids["gestion"]
    mac_address = var.router_macs[each.key]["gestion"]
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
    tenants = sha1(jsonencode(local.tenant_config))
    system  = sha1(jsonencode(local.system_config))
    dhcp    = join(",", var.dhcp_server_ips)
    dns     = join(",", var.dns_server_ips)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Un inventaire par noeud : les runs tournent en parallele dans le meme dossier.
    # Rebond par le bastion unique, avec son mot de passe (sshpass requis sur la machine Terraform).
    # Le mot de passe est ecrit dans un fichier temporaire 0600 (jamais dans la ligne de commande).
    command = <<-EOT
      set -euo pipefail
      umask 077
      PASSFILE=$(mktemp)
      trap 'rm -f "$PASSFILE" inventory-${each.key}.ini' EXIT
      printf '%s' "$BASTION_SSH_PASSWORD" > "$PASSFILE"

      PROXY="sshpass -f $PASSFILE ssh -W %h:%p -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o PreferredAuthentications=password $BASTION_SSH_USER@$BASTION_IP"
      printf '[pfsense]\nrouter ansible_host=%s ansible_user=admin ansible_ssh_pass=admin ansible_ssh_common_args=%s\n' \
        "$ROUTER_IP" "'-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand=\"$PROXY\"'" > inventory-${each.key}.ini
      ansible-playbook -i inventory-${each.key}.ini playbook.yml
    EOT

    working_dir = "${path.module}/ansible"

    environment = {
      ROUTER_IP            = local.gestion_ips[each.key]
      VNET_CONFIGS_JSON    = jsonencode(local.router_configs[each.key])
      TENANT_CONFIG_JSON   = jsonencode(local.tenant_config)
      SYSTEM_CONFIG_JSON   = jsonencode(local.system_config)
      DHCP_SERVER_IP       = join(",", var.dhcp_server_ips)
      DNS_SERVERS          = join(",", var.dns_server_ips)
      BASTION_IP           = var.bastion_wan_ip
      BASTION_SSH_USER     = var.bastion_ssh_user
      BASTION_SSH_PASSWORD = var.bastion_ssh_password
    }
  }
}

# =========================================================================
# SORTIES
# =========================================================================

output "ids" {
  value = { for k, vm in xenorchestra_vm.vm_routeur : k => vm.id }
}

output "gestion_ips" {
  value = local.gestion_ips
}
