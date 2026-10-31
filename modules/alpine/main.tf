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
  name_label = var.template_name
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

  # pfSense sur transit : .1 a .gateway_number (candidats du failover)
  gateways     = [for k in range(1, var.gateway_number + 1) : cidrhost(var.transit_cidr, k)]
  gateways_b64 = base64encode("${join("\n", local.gateways)}\n")

  script_b64 = base64encode(file("${path.module}/failover.sh"))

  # Reseaux users de chaque noeud, dans l'ordre : le 1er sera enX1, le 2e enX2, etc. (enX0 = transit)
  node_tenants = {
    for n, _ in local.nodes : n => [
      for i in range(0, length(var.tenants)) : "tenant${i}"
      if var.tenant_nodes["tenant${i}"] == tonumber(n)
    ]
  }

  # MAC de la patte alpine sur chaque tenant : 5e octet = noeud (comme les routeurs)
  tenant_macs = {
    for k, v in var.tenants : k => join(":", concat(
      slice(split(":", v.mac), 0, 4),
      [format("%02x", var.tenant_nodes[k])],
      slice(split(":", v.mac), 5, 6)
    ))
  }

  # MAC de l'alpine sur transit (distincte de celle des pfSense : 4e octet = 02)
  transit_macs = { for n, _ in local.nodes : n => format("02:00:00:02:%02x:02", tonumber(n)) }

  # Relais DHCP uniquement : un relais par reseau user (adresse locale = .1 de l'alpine) vers chaque Kea.
  # Pas de DNS, pas de bail local. Filtrage : seule la regle nftables tenant -> tenant (cloud-config), le reste est sur les pfSense.
  dnsmasq_conf = {
    for n, _ in local.nodes : n => join("\n", concat(
      ["# genere par Terraform : relais DHCP vers Kea", "port=0"],
      flatten([
        for t in local.node_tenants[n] : [
          for s in var.dhcp_server_ips : "dhcp-relay=${var.tenants[t].ip_emi},${s}"
        ]
      ]),
      [""]
    ))
  }
  dnsmasq_b64 = { for n, c in local.dnsmasq_conf : n => base64encode(c) }
}

# =========================================================================
# VM "ALPINE" : passerelle (routage, relais DHCP, une regle nftables), une par hote, routeur des reseaux users de cet hote
# =========================================================================

resource "xenorchestra_vm" "vm_alpine" {
  for_each         = local.nodes
  name_label       = "VM-Alpine-${each.key}"
  name_description = "Passerelle des reseaux users du noeud ${each.key} (Terraform)"
  host             = each.value

  template          = data.xenorchestra_template.debian.id
  cpus              = var.cpus
  memory_max        = var.memory_max
  hvm_boot_firmware = "bios"

  # enX0 : transit (vers les pfSense)
  network {
    network_id  = var.transit_network_id
    mac_address = local.transit_macs[each.key]
  }
  # enX1.. : les reseaux users de CE noeud (meme nombre pour toutes les alpines)
  dynamic "network" {
    for_each = local.node_tenants[each.key]
    iterator = t
    content {
      network_id  = var.tenant_network_ids[t.value]
      mac_address = local.tenant_macs[t.value]
    }
  }

  cloud_config = <<-EOF
      #cloud-config

      hostname: VM-Alpine-${each.key}
      manage_etc_hosts: true

      # Passerelle : routage + relais DHCP + failover vers les pfSense + une seule regle de fermeture
      package_update: true
      packages:
        - iproute2         # ip route / ip link (failover)
        - iputils-ping     # sonde des pfSense par le failover
        - dnsmasq          # relais DHCP vers Kea
        - nftables         # ferme le tenant -> tenant local

      write_files:
        - path: /etc/failover/node-id
          permissions: '0644'
          content: |
            ${each.key}
        - path: /etc/failover/gateways-list
          encoding: b64
          permissions: '0644'
          content: ${local.gateways_b64}
        - path: /etc/failover/env
          permissions: '0644'
          content: |
            IFACE_MAC=${local.transit_macs[each.key]}
            ROUTE_DEST=${var.route_dest}
        - path: /usr/local/bin/failover.sh
          encoding: b64
          permissions: '0755'
          content: ${local.script_b64}
        - path: /etc/systemd/system/failover.service
          permissions: '0644'
          content: |
            [Unit]
            Description=Bascule de passerelle alpine vers pfSense (transit)
            Wants=network-online.target
            After=network-online.target
            ConditionPathExists=/etc/failover/gateways-list
            ConditionPathExists=/etc/failover/node-id
            [Service]
            ExecStart=/usr/local/bin/failover.sh
            Restart=always
            RestartSec=5
            [Install]
            WantedBy=multi-user.target
        - path: /etc/sysctl.d/90-gateway.conf
          permissions: '0644'
          content: |
            net.ipv4.ip_forward = 1
            net.ipv4.conf.all.rp_filter = 2
            net.ipv4.conf.default.rp_filter = 2
        # Seul filtre des alpines : un paquet venu d'un reseau user ne peut pas ressortir vers un autre
        # reseau user du meme noeud (il ne peut aller que vers pfSense, via transit enX0).
        # Tout le reste (dont les tenants des autres noeuds) est filtre par les pfSense.
        - path: /etc/nftables.conf
          permissions: '0644'
          defer: true
          content: |
            #!/usr/sbin/nft -f
            flush ruleset
            table inet gateway {
              chain forward {
                type filter hook forward priority 0; policy accept;
                iifname != "enX0" oifname != "enX0" counter drop
              }
            }
        - path: /etc/dnsmasq.d/relay.conf
          encoding: b64
          permissions: '0644'
          content: ${local.dnsmasq_b64[each.key]}

      runcmd:
        - sysctl -p /etc/sysctl.d/90-gateway.conf
        - systemctl daemon-reload
        - systemctl enable --now failover.service
        - systemctl enable dnsmasq
        - systemctl restart dnsmasq
        - systemctl enable nftables
        - systemctl restart nftables
  EOF

  # enX0 = transit, enX1.. = tenants, nommes par MAC (robuste a l'ordre des VIF)
  cloud_network_config = yamlencode({
    version = 1
    config = concat(
      [{
        type        = "physical"
        name        = "enX0"
        mac_address = local.transit_macs[each.key]
        subnets     = [{ type = "static", address = "${var.alpine_ips[each.key]}/${split("/", var.transit_cidr)[1]}" }]
      }],
      [
        for idx, t in local.node_tenants[each.key] : {
          type        = "physical"
          name        = "enX${idx + 1}"
          mac_address = local.tenant_macs[t]
          subnets     = [{ type = "static", address = "${var.tenants[t].ip_emi}/${var.tenants[t].prefix}" }]
        }
      ]
    )
  })

  disk {
    name_label = "VM-Alpine-${each.key}-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = var.disk_size
  }
}

# =========================================================================
# SORTIES
# =========================================================================

output "ids" {
  value = { for k, vm in xenorchestra_vm.vm_alpine : k => vm.id }
}

output "transit_ips" {
  value = var.alpine_ips
}

output "tenants_by_node" {
  value = local.node_tenants
}
