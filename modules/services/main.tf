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

# =========================================================================
# LOCALS
# =========================================================================

locals {
  node_count = length(var.hosts)
  nodes      = { for i, h in var.hosts : tostring(i) => h }

  # --- Failover (script commun aux VM en contact direct avec les pfSense) ---
  gateways     = [for k in range(1, var.gateway_number + 1) : cidrhost(var.gateways_cidr, k)]
  gateways_b64 = base64encode("${join("\n", local.gateways)}\n")
  script_b64   = base64encode(file("${path.module}/failover.sh"))
  prefix       = split("/", var.gateways_cidr)[1]

  failover_unit = <<-UNIT
    [Unit]
    Description=Bascule de passerelle par defaut (VM cliente)
    Wants=network-online.target
    After=network-online.target
    ConditionPathExists=/etc/failover/gateways-list
    ConditionPathExists=/etc/failover/node-id
    [Service]
    Environment=IFACE=enX0
    ExecStart=/usr/local/bin/failover.sh
    Restart=always
    RestartSec=5
    [Install]
    WantedBy=multi-user.target
  UNIT

  # --- DNS : svc-net-0 = maitre, tous les autres = esclaves (autant que d'hotes - 1) ---
  master_ip = var.svc_net_ips[0]
  slave_ips = slice(var.svc_net_ips, 1, local.node_count)

  bind_allowed_cidrs = [for v in values(var.all_vnets) : v.ip]
  bind_allowed_str   = join("; ", concat(local.bind_allowed_cidrs, ["localhost"]))

  zone_file = join("\n", concat(
    [
      "$TTL    604800",
      "@       IN      SOA     dns-1.${var.domain}. admin.${var.domain}. (",
      "                              1       ; Serial",
      "                           3600       ; Refresh",
      "                            300       ; Retry",
      "                        2419200       ; Expire",
      "                           3600 )     ; Negative Cache TTL",
      ";",
    ],
    [for n in range(local.node_count) : "@        IN      NS      dns-${n + 1}.${var.domain}."],
    [for n in range(local.node_count) : "dns-${n + 1}    IN      A       ${var.svc_net_ips[n]}"],
    [for n in range(local.node_count) : "svc-net-${n}  IN      A       ${var.svc_net_ips[n]}"],
    # NetBox tourne sur chaque svc-net : un nom unique a plusieurs A
    [for n in range(local.node_count) : "netbox   IN      A       ${var.svc_net_ips[n]}"],
    [""]
  ))

  # --- Kea : un serveur par svc-net ---
  dhcp_keys = keys(var.dhcp_vnets)

  # id explicite et stable : les baux repliques entre serveurs HA sont identifies par id de subnet
  subnets_kea = [
    for idx, key in local.dhcp_keys : {
      id     = idx + 1
      subnet = var.dhcp_vnets[key].ip
      pools = [{
        pool = "${cidrhost(var.dhcp_vnets[key].ip, 11)} - ${cidrhost(var.dhcp_vnets[key].ip, 254)}"
      }]
      option-data = [
        { name = "routers", data = var.dhcp_vnets[key].ip_emi },
        { name = "domain-name-servers", data = join(", ", var.svc_net_ips) },
        { name = "domain-name", data = var.domain, always-send = true }
      ]
      user-context = { description = var.dhcp_vnets[key].name }
    }
  ]

  # HA : 2 serveurs actifs maximum (primary + standby), les suivants sont "backup"
  # (ils recoivent les baux, ne repondent jamais aux clients)
  ha_role = [for n in range(local.node_count) : n == 0 ? "primary" : (n == 1 ? "standby" : "backup")]
  ha_peers = [
    for n in range(local.node_count) : {
      name          = "svc-net-${n}"
      url           = "http://${var.svc_net_ips[n]}:${var.kea_ha_port}/"
      role          = local.ha_role[n]
      auto-failover = local.ha_role[n] != "backup"
    }
  ]

  kea_dhcp4 = {
    for n in range(local.node_count) : tostring(n) => jsonencode({
      Dhcp4 = {
        interfaces-config = { interfaces = ["enX0/${var.svc_net_ips[n]}"] }
        control-socket    = { socket-type = "unix", socket-name = "/run/kea/kea4-ctrl-socket" }
        lease-database    = { type = "memfile", persist = true, name = "/var/lib/kea/kea-leases4.csv", lfc-interval = 3600 }
        valid-lifetime    = 4000
        multi-threading   = { enable-multi-threading = true, thread-pool-size = 0 }
        hooks-libraries = concat(
          [{ library = "libdhcp_lease_cmds.so" }],
          [
            for _ in range(local.node_count >= 2 ? 1 : 0) : {
              library = "libdhcp_ha.so"
              parameters = {
                high-availability = [{
                  this-server-name   = "svc-net-${n}"
                  mode               = "hot-standby"
                  heartbeat-delay    = 10000
                  max-response-delay = 60000
                  multi-threading = {
                    enable-multi-threading  = true
                    http-dedicated-listener = true
                    http-listener-threads   = 0
                    http-client-threads     = 0
                  }
                  peers = local.ha_peers
                }]
              }
            }
          ]
        )
        dhcp-ddns              = { enable-updates = true, server-ip = "127.0.0.1", server-port = 53001 }
        ddns-qualifying-suffix = var.domain
        subnet4                = local.subnets_kea
      }
    })
  }

  # API Kea (utilisee par l'agent reseau) : Control Agent sur le port 8000 de chaque svc-net
  kea_ctrl_agent = {
    for n in range(local.node_count) : tostring(n) => jsonencode({
      Control-agent = {
        http-host = var.svc_net_ips[n]
        http-port = 8000
        authentication = {
          type    = "basic"
          realm   = "kea-api"
          clients = [{ user = "gandal", password = var.kea_api_password }]
        }
        control-sockets = {
          dhcp4 = { socket-type = "unix", socket-name = "/run/kea/kea4-ctrl-socket" }
          d2    = { socket-type = "unix", socket-name = "/run/kea/kea-dhcp-ddns-ctrl-socket" }
        }
      }
    })
  }

  # DDNS : toutes les mises a jour partent vers le maitre bind
  kea_d2 = jsonencode({
    DhcpDdns = {
      ip-address     = "127.0.0.1"
      port           = 53001
      control-socket = { socket-type = "unix", socket-name = "/run/kea/kea-dhcp-ddns-ctrl-socket" }
      forward-ddns = {
        ddns-domains = [{
          name        = "${var.domain}."
          dns-servers = [{ ip-address = local.master_ip, port = 53 }]
        }]
      }
      reverse-ddns = {}
    }
  })

  # --- bind ---
  named_options = {
    for n in range(local.node_count) : tostring(n) => join("\n", [
      "options {",
      "    directory \"/var/cache/bind\";",
      "    recursion yes;",
      "    listen-on { 127.0.0.1; ${var.svc_net_ips[n]}; };",
      "    listen-on-v6 { any; };",
      "    allow-query { ${local.bind_allowed_str}; };",
      "    allow-recursion { ${local.bind_allowed_str}; };",
      n == 0 ? "    allow-transfer { ${join("; ", local.slave_ips)}${local.node_count > 1 ? ";" : ""} };" : "    allow-transfer { none; };",
      n == 0 ? "    also-notify { ${join("; ", local.slave_ips)}${local.node_count > 1 ? ";" : ""} };" : "    also-notify { none; };",
      "    forwarders { ${join("; ", var.forwarders)}; };",
      "    dnssec-validation auto;",
      "    auth-nxdomain no;",
      "};",
      ""
    ])
  }

  named_local = {
    for n in range(local.node_count) : tostring(n) => (n == 0 ?
      join("\n", [
        "zone \"${var.domain}\" {",
        "    type master;",
        "    file \"db.${var.domain}\";",
        "    allow-update { ${join("; ", var.svc_net_ips)}; };",
        "};",
        ""
      ]) :
      join("\n", [
        "zone \"${var.domain}\" {",
        "    type secondary;",
        "    primaries { ${local.master_ip}; };",
        "    file \"db.${var.domain}\";",
        "};",
        ""
      ])
    )
  }

  # --- NetBox (netbox-docker), expose sur l'IP du svc-net ---
  netbox_override = {
    for n in range(local.node_count) : tostring(n) => join("\n", [
      "services:",
      "  netbox:",
      "    env_file:",
      "      - env/superuser.env",
      "    ports:",
      "      - \"${var.svc_net_ips[n]}:8081:8080\"",
      "  postgres:",
      "    volumes:",
      "      - /srv/netbox/postgres-data:/var/lib/postgresql/data",
      "  redis:",
      "    volumes:",
      "      - /srv/netbox/redis-data:/data",
      "  redis-cache:",
      "    volumes:",
      "      - /srv/netbox/redis-cache-data:/data",
      ""
    ])
  }

  netbox_superuser_env = join("\n", [
    "SUPERUSER_NAME=admin",
    "SUPERUSER_EMAIL=admin@${var.domain}",
    "SUPERUSER_PASSWORD=${var.netbox_superuser_password}",
    "SUPERUSER_API_TOKEN=${var.netbox_api_token}",
    ""
  ])

  # --- cloud-config de chaque svc-net ---
  user_data = {
    for n in range(local.node_count) : tostring(n) => "#cloud-config\n${yamlencode({
      hostname         = "svc-net-${n}"
      fqdn             = "svc-net-${n}.${var.domain}"
      manage_etc_hosts = true

      package_update  = true
      package_upgrade = false
      packages = [
        "ca-certificates", "curl", "gnupg", "lsb-release", "git",
        "python3", "python3-pip", "sqlite3", "netcat-openbsd",
        "iproute2", "iputils-ping", "chrony",
        "bind9", "bind9utils", "dnsutils",
        "kea-dhcp4-server", "kea-dhcp-ddns-server", "kea-ctrl-agent",
      ]

      write_files = concat(
        [
          # --- failover vers les pfSense du vnet SERVICES (n = noeud = pfSense de base) ---
          { path = "/etc/failover/node-id", permissions = "0644", content = "${n}\n" },
          { path = "/etc/failover/gateways-list", permissions = "0644", encoding = "b64", content = local.gateways_b64 },
          { path = "/usr/local/bin/failover.sh", permissions = "0755", encoding = "b64", content = local.script_b64 },
          { path = "/etc/systemd/system/failover.service", permissions = "0644", content = local.failover_unit },
          # --- bind (ecrit apres l'installation des paquets) ---
          { path = "/etc/bind/named.conf.options", defer = true, permissions = "0644", encoding = "b64", content = base64encode(local.named_options[tostring(n)]) },
          { path = "/etc/bind/named.conf.local", defer = true, permissions = "0644", encoding = "b64", content = base64encode(local.named_local[tostring(n)]) },
          # --- Kea ---
          { path = "/etc/kea/kea-dhcp4.conf", defer = true, permissions = "0644", encoding = "b64", content = base64encode(local.kea_dhcp4[tostring(n)]) },
          { path = "/etc/kea/kea-ctrl-agent.conf", defer = true, permissions = "0644", encoding = "b64", content = base64encode(local.kea_ctrl_agent[tostring(n)]) },
          { path = "/etc/kea/kea-dhcp-ddns.conf", defer = true, permissions = "0644", encoding = "b64", content = base64encode(local.kea_d2) },
          # --- NetBox : ecrits dans /opt/netbox, le depot est clone puis copie par-dessus (ces 2 fichiers n'existent pas dans le depot) ---
          { path = "/opt/netbox/docker-compose.override.yml", permissions = "0644", encoding = "b64", content = base64encode(local.netbox_override[tostring(n)]) },
          { path = "/opt/netbox/env/superuser.env", permissions = "0600", encoding = "b64", content = base64encode(local.netbox_superuser_env) },
        ],
        # zone du domaine : uniquement sur le maitre
        [
          for _ in range(n == 0 ? 1 : 0) : {
            path        = "/var/cache/bind/db.${var.domain}"
            defer       = true
            permissions = "0644"
            encoding    = "b64"
            content     = base64encode(local.zone_file)
          }
        ]
      )

      runcmd = [
        # 1. reseau et horloge
        "systemctl daemon-reload",
        "systemctl enable --now failover.service",
        "systemctl enable --now chrony",
        # 2. DNS d'abord (cible du DDNS de Kea), puis Kea dans l'ordre : d2, dhcp4, agent (qui lit leurs sockets)
        "systemctl enable named",
        "systemctl restart named",
        "systemctl enable kea-dhcp-ddns-server kea-dhcp4-server kea-ctrl-agent",
        "systemctl restart kea-dhcp-ddns-server",
        "systemctl restart kea-dhcp4-server",
        "systemctl restart kea-ctrl-agent",
        # 3. NetBox en dernier : il depend d'Internet, une panne ici ne doit pas bloquer DNS/DHCP
        "curl -fsSL https://get.docker.com | sh",
        "systemctl enable --now docker",
        "mkdir -p /srv/netbox/postgres-data /srv/netbox/redis-data /srv/netbox/redis-cache-data",
        "git clone -b release --depth 1 https://github.com/netbox-community/netbox-docker.git /tmp/netbox-docker",
        "cp -a /tmp/netbox-docker/. /opt/netbox/",
        "rm -rf /tmp/netbox-docker",
        "cd /opt/netbox && docker compose pull && docker compose up -d",
      ]

      final_message = "svc-net-${n} est pret apres $UPTIME secondes"
    })}"
  }
}

# =========================================================================
# svc-net : UNE VM PAR HOTE (bind9 + Kea + NetBox + agent reseau)
# =========================================================================

resource "xenorchestra_vm" "svc_net" {
  for_each         = local.nodes
  name_label       = "svc-net-${each.key}"
  name_description = "svc-net : DNS (bind9), DHCP (Kea), NetBox - noeud ${each.key} (Terraform)"
  host             = each.value

  template          = data.xenorchestra_template.debian.id
  cpus              = var.cpus
  memory_max        = var.memory_max
  hvm_boot_firmware = "bios"

  network {
    network_id = var.network_id
  }

  cloud_config = local.user_data[each.key]

  # IP fixe sur SERVICES ; passerelle initiale = pfSense du meme noeud (le failover prend ensuite le relais)
  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: ${var.svc_net_ips[tonumber(each.key)]}/${local.prefix}
            gateway: ${cidrhost(var.gateways_cidr, tonumber(each.key) + 1)}
            dns_nameservers: ${jsonencode(var.forwarders)}
  EOF

  disk {
    name_label = "svc-net-${each.key}-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = var.disk_size
  }
}

# =========================================================================
# SORTIES
# =========================================================================

output "ids" {
  value = { for k, vm in xenorchestra_vm.svc_net : k => vm.id }
}

output "ips" {
  value = var.svc_net_ips
}

output "netbox_urls" {
  value = [for ip in var.svc_net_ips : "http://${ip}:8081"]
}
