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

locals {

  dhcp_keys_sorted = sort(keys(var.dhcp_vnets))

  subnets_kea = [
    for key in local.dhcp_keys_sorted : {
      subnet = var.dhcp_vnets[key].ip
      pools  = [{
        pool = "${cidrhost(var.dhcp_vnets[key].ip, 50)} - ${cidrhost(var.dhcp_vnets[key].ip, 200)}"
      }]
      option-data = [
        { name = "routers", data = var.dhcp_vnets[key].ip_y },
        { name = "domain-name-servers", data = "10.0.20.2" },
        { name = "domain-name", data = "gandal.internal", always-send = true }
      ]
      user-context = { description = var.dhcp_vnets[key].name }
    }
  ]

  kea_config = jsonencode({
    Dhcp4 = {
      "interfaces-config" = { interfaces = ["*"] }
      "control-socket"    = { "socket-type" = "unix", "socket-name" = "/tmp/kea4-ctrl-socket" }
      "lease-database"    = { type = "memfile", "lfc-interval" = 3600 }
      "valid-lifetime"    = 4000
      subnet4             = local.subnets_kea
    }
  })

  bind_allowed_cidrs = [for v in values(var.all_vnets) : v.ip]
  bind_allowed_str   = join("; ", concat(local.bind_allowed_cidrs, ["localhost"]))
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

  cloud_config = <<-EOF
      #cloud-config
      hostname: VM-DNS
      manage_etc_hosts: true

      package_update: true
      packages:
        - bind9
        - bind9utils
        - dnsutils

      write_files:
        - path: /etc/bind/named.conf.options
          content: |
            options {
                directory "/var/cache/bind";
                recursion yes;
                listen-on { any; };
                listen-on-v6 { none; };
                // Adaptez à votre ou vos VNets
                allow-query {${local.bind_allowed_str}; };
                allow-recursion {${local.bind_allowed_str}; };
                forwarders { 8.8.8.8; 1.1.1.1; };
                dnssec-validation auto;
                auth-nxdomain no;
            };
        - path: /etc/bind/named.conf.local
          content: |
            zone "gandal.internal" {
                type master;
                file "/etc/bind/db.gandal.internal";
                allow-transfer { none; };
            };
        - path: /etc/bind/db.gandal.internal
          content: |
            $TTL    604800
            @       IN      SOA     ns1.gandal.internal. admin.gandal.internal. (
                                          2024010101 ; Serial
                                              604800 ; Refresh
                                                86400 ; Retry
                                              2419200 ; Expire
                                              604800 ) ; Negative Cache TTL
            ;
            @        IN      NS      ns1.gandal.internal.
            ns1      IN      A       10.0.20.2
            dhcp     IN      A       10.0.20.3
            netbox   IN      A       10.0.20.4

      runcmd:
        - named-checkconf
        - systemctl restart bind9
        - systemctl enable bind9
  EOF
  # les configurations dns a inserer ici

  cloud_network_config = <<-EOF
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

  cloud_config = <<-EOF
      #cloud-config
      hostname: VM-DHCP
      manage_etc_hosts: true

      package_update: true
      packages:
        - curl
        - gnupg
        - apt-transport-https

      runcmd:
        - curl -1sLf 'https://dl.cloudsmith.io/public/isc/kea-2-6/setup.deb.sh' | bash
        - apt-get update
        - apt-get install -y isc-kea-common isc-kea-dhcp4-server isc-kea-ctrl-agent

        # === CONFIGURATION KEA DHCPv4 ===
        # C'est ICI que vous déclarez vos VNets, plages et options.
        - |
          cat > /etc/kea/kea-dhcp4.conf <<'KEAEOF'
          ${local.kea_config}
          KEAEOF

        # === CONFIGURATION CONTROL AGENT (pour NetBox) ===
        - |
          cat > /etc/kea/kea-ctrl-agent.conf <<'CEOF'
          {
            "Control-agent": {
              "http-host": "0.0.0.0",
              "http-port": 8000,
              "control-sockets": {
                "dhcp4": {
                  "socket-type": "unix",
                  "socket-name": "/tmp/kea4-ctrl-socket"
                }
              }
            }
          }
          CEOF

        - systemctl restart isc-kea-dhcp4-server
        - systemctl enable isc-kea-dhcp4-server
        - systemctl restart isc-kea-ctrl-agent
        - systemctl enable isc-kea-ctrl-agent
        EOF

  cloud_network_config = <<-EOF
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
    name_label = "VM-DHCP-disk"
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

  cloud_config = <<-EOF
      #cloud-config

      hostname: VM-NetBox
      manage_etc_hosts: true

      package_update: true
      packages:
        - postgresql
        - redis-server
        - nginx
        - python3-pip
        - python3-venv
        - python3-dev
        - build-essential
        - libxml2-dev
        - libxslt1-dev
        - libffi-dev
        - libssl-dev
        - zlib1g-dev
        - git
        - curl

      runcmd:
        # PostgreSQL
        - sudo -u postgres psql -c "CREATE DATABASE netbox;"
        - sudo -u postgres psql -c "CREATE USER netbox WITH PASSWORD 'netbox_password_securise';"
        - sudo -u postgres psql -c "ALTER DATABASE netbox OWNER TO netbox;"
        - sudo -u postgres psql -c "GRANT CREATE ON SCHEMA public TO netbox;"

        # Installation NetBox
        - git clone -b v4.2.0 https://github.com/netbox-community/netbox.git /opt/netbox
        - useradd --system --group netbox
        - chown --recursive netbox /opt/netbox/netbox/media/

        # Configuration de base
        - |
          cd /opt/netbox/netbox/netbox/
          cp configuration_example.py configuration.py
          # SECRET_KEY généré avec le python système (stdlib uniquement)
          SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
          sed -i "s|SECRET_KEY = ''|SECRET_KEY = '$SECRET_KEY'|" configuration.py
          sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" configuration.py
          sed -i "s/PASSWORD': 'netbox'/PASSWORD': 'netbox_password_securise'/" configuration.py
          echo "PLUGINS = ['netbox_kea']" >> configuration.py

        # Dépendances et plugin
        - echo "netbox-kea-ng" >> /opt/netbox/local_requirements.txt
        - /opt/netbox/upgrade.sh
        - chown -R netbox:netbox /opt/netbox

        # Services

        # Services
        - systemctl start netbox
        - systemctl enable netbox
        - systemctl start netbox-rq
        - systemctl enable netbox-rq

        # Nginx
        - |
          cat > /etc/nginx/sites-available/netbox <<'CEOF'
          server {
              listen 80;
              server_name _;
              location / {
                  proxy_pass http://127.0.0.1:8001;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
              }
          }
          CEOF
        - ln -sf /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox
        - rm -f /etc/nginx/sites-enabled/default
        - systemctl restart nginx
  EOF
  # les configurations netbox a inserer ici

  cloud_network_config = <<-EOF
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

  cloud_config = <<-EOF
      #cloud-config

      hostname: VM-KeyCloak
      manage_etc_hosts: true
  EOF
  # les configurations keycloak a inserer ici

  cloud_network_config = <<-EOF
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

  cloud_config = <<-EOF
      #cloud-config

      hostname: VM-Mail
      manage_etc_hosts: true
  EOF
  # les configurations pour qu'il recoive les redirections du portail

  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.50.3/24
            gateway: 10.0.50.1/24
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