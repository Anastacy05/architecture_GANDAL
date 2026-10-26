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
  name_label = "Debian-Template-Base"
  pool_id    = var.pool
}

data "xenorchestra_sr" "sr_local" {
  name_label = "Local Storage"
  pool_id    = var.pool
}

data "xenorchestra_network" "pool_network" {
  name_label = "Pool-wide network 0"
}


# =========================================================================
# LOCALS
# =========================================================================

locals {

  nodes = { for i, h in var.hosts: tostring(i) => h }

  gateways = [for k in range(1, var.gateway_number+1): cidrhost(var.gateways_cidr, k)]
  gateways_b64  = base64encode("${join("\n", local.gateways)}\n")

  script_b64    = base64encode(file("${path.module}/failover.sh"))

}

# =========================================================================
# VMs
# =========================================================================

resource "xenorchestra_vm" "vm_bastion" {

  for_each = local.nodes
  name_label = "VM-Bastion-${each.key}"
  name_description = "VM Bastion créée avec Terraform"
  host = each.value

  template = data.xenorchestra_template.debian.id
  cpus       = 1
  memory_max = 4 * 1073741824
  hvm_boot_firmware = "bios"

  network {
      network_id  = data.xenorchestra_network.pool_network.id
      expected_ip_cidr = "192.168.122.0/24"
  }
  network {
      network_id  = var.network_id
  }

  cloud_config = <<EOF
      #cloud-config
      hostname: VM-Portail-${each.key}
      manage_etc_hosts: true

      write-files:
        - path: /etc/failover/node-id
          permissions: '0644'
          content: |
            ${each.key}
        - path: /etc/failover/gateways-list
          encoding: b64
          permissions: '0644'
          content: ${local.gateways_b64}
        - path: /usr/local/bin/failover.sh
          encoding: b64
          permissions: '0755'
          content: ${local.script_b64}
        - path: /etc/systemd/system/failover.service
          content: |
            [Unit]
            Description=Bascule de passerelle en cas de rupture de signal
            Wants=network-online.target
            After=network-online.target
            ConditionPathExists=/etc/failover/gateways-list
            ConditionPathExists=/etc/failover/node-id
            [Service]
            Environment=IFACE=enX1
            Environment=INTERNAL_CIDR=${var.internal_cidr}
            ExecStart=/usr/local/bin/failover.sh
            Restart=always
            RestartSec=5
            [Install]
            WantedBy=multi-user.target

      runcmd:
        - systemctl daemon-reload
        - systemctl enable --now failover.service
  EOF

  cloud_network_config = <<EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: dhcp
      - type: physical
        name: enX1
        subnets:
          - type: static
            address: ${cidrhost(var.gateways_cidr, var.gateway_number+tonumber(each.key)+1)}/24
  EOF	

  disk {
    name_label = "VM-Bastion-${each.key}-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}


# =========================================================================
# SORTIE
# =========================================================================

output "ids" {
  value = { for k, vm in xenorchestra_vm.vm_bastion : k => vm.id }
}

output "wan_ips" {
  value = {
    for k, vm in xenorchestra_vm.vm_bastion :
    k => [for ip in vm.ipv4_addresses : ip if startswith(ip, "192.168.122.")][0]
  }
}