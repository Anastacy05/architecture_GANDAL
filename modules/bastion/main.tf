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

  # Routeurs pfSense sur GESTION : .1 a .gateway_number (un par noeud + candidats de failover)
  gateways     = [for k in range(1, var.gateway_number + 1) : cidrhost(var.gestion_cidr, k)]
  gateways_b64 = base64encode("${join("\n", local.gateways)}\n")

  # IP du bastion sur GESTION (juste apres la plage des routeurs)
  bastion_ip = cidrhost(var.gestion_cidr, var.gateway_number + 1)

  script_b64 = base64encode(file("${path.module}/failover.sh"))

  wan_access_elements = join(", ", var.wan_access_cidrs)

  # Le bastion est le SEUL serveur DHCP de GESTION : il sert les 3 routeurs (un bail fixe par MAC)
  dnsmasq_conf = join("\n", concat([
    "# genere par Terraform",
    "port=0",
    "interface=enX1",
    "bind-interfaces",
    "dhcp-authoritative",
    "dhcp-range=${cidrhost(var.gestion_cidr, 0)},static,${cidrnetmask(var.gestion_cidr)}",
    "dhcp-option=3",
  ], [
    for n, mac in var.router_gestion_macs :
    "dhcp-host=${mac},${cidrhost(var.gestion_cidr, tonumber(n) + 1)}"
  ]))
  dnsmasq_b64 = base64encode("${local.dnsmasq_conf}\n")

}

# =========================================================================
# VM (unique, sur emilia)
# =========================================================================

# Anciennement 1 bastion par noeud (for_each) : on garde l'etat du noeud 0
moved {
  from = xenorchestra_vm.vm_bastion["0"]
  to   = xenorchestra_vm.vm_bastion
}

resource "xenorchestra_vm" "vm_bastion" {

  name_label       = "VM-Bastion"
  name_description = "VM Bastion unique (emilia) créée avec Terraform"
  host             = var.host

  template          = data.xenorchestra_template.debian.id
  cpus              = 1
  memory_max        = 4 * 1073741824
  hvm_boot_firmware = "bios"

  network {
    network_id       = data.xenorchestra_network.pool_network.id
    expected_ip_cidr = "192.168.122.0/24"
  }
  network {
    network_id = var.network_id
  }

  cloud_config = <<-EOF
      #cloud-config
      hostname: VM-Bastion
      manage_etc_hosts: true
      ssh_pwauth: true

      package_update: true
      packages:
        - dnsmasq
        - iputils-ping
        - nftables

      write_files:
        - path: /etc/failover/node-id
          permissions: '0644'
          content: |
            0
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
        # Le bastion est la sortie Internet de tout le reseau interne : routage + NAT (enX0 = WAN, enX1 = gestion).
        # Les pfSense n'ont pas de NAT ; ils envoient tout le trafic Internet au bastion.
        # Seul le trafic ROUTE (forward) est filtre ; l'acces au bastion lui-meme (SSH, rebond) n'est pas touche.
        - path: /etc/sysctl.d/90-nat.conf
          permissions: '0644'
          content: |
            net.ipv4.ip_forward = 1
        - path: /etc/nftables.conf
          permissions: '0644'
          defer: true
          content: |
            #!/usr/sbin/nft -f
            flush ruleset
            table inet nat_bastion {
              # reseaux internes joignables depuis le Pool-wide (VM users)
              set wan_access {
                type ipv4_addr
                flags interval
                elements = { ${local.wan_access_elements} }
              }
              chain forward {
                type filter hook forward priority 0; policy drop;
                ct state established,related accept
                # interne -> Internet
                iifname "enX1" oifname "enX0" accept
                # Pool-wide -> VM users : le navigateur tape l'URL de la VM
                iifname "enX0" oifname "enX1" ip daddr @wan_access tcp dport ${var.wan_access_dports} accept
              }
              chain postrouting {
                type nat hook postrouting priority 100; policy accept;
                # interne -> Internet
                oifname "enX0" ip saddr ${var.internal_cidr} masquerade
                # Pool-wide -> interne : la VM voit l'IP du bastion sur gestion et lui repond (gestion est autorisee par la matrice)
                oifname "enX1" ip saddr != ${var.internal_cidr} masquerade
              }
            }
        - path: /etc/dnsmasq.d/gestion.conf
          encoding: b64
          permissions: '0644'
          content: ${local.dnsmasq_b64}

      runcmd:
        - sysctl -p /etc/sysctl.d/90-nat.conf
        - systemctl enable nftables
        - systemctl restart nftables
        - systemctl daemon-reload
        - systemctl enable --now failover.service
        - systemctl enable dnsmasq
        - systemctl restart dnsmasq
  EOF

  cloud_network_config = <<-EOF
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
            address: ${local.bastion_ip}/24
  EOF

  disk {
    name_label = "VM-Bastion-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }

}


# =========================================================================
# SORTIE
# =========================================================================

output "id" {
  value = xenorchestra_vm.vm_bastion.id
}

output "wan_ip" {
  value = [for ip in xenorchestra_vm.vm_bastion.ipv4_addresses : ip if startswith(ip, "192.168.122.")][0]
}

output "gestion_ip" {
  value = local.bastion_ip
}
