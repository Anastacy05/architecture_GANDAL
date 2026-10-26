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
locals {

  dhcp_keys = keys(var.dhcp_vnets)

  subnets_kea = [
    for key in local.dhcp_keys : {
      subnet = var.dhcp_vnets[key].ip
      pools  = [{
        pool = "${cidrhost(var.dhcp_vnets[key].ip, 11)} - ${cidrhost(var.dhcp_vnets[key].ip, 254)}"
      }]
      option-data = [
        { name = "routers", data = var.var.dhcp_vnets[key].ip_emi },
        { name = "domain-name-servers", data = "10.0.10.14, 10.0.10.15, 10.0.10.16" },
        { name = "domain-name", data = "gandal.internal", always-send = true }
      ]
      user-context = { description = var.dhcp_vnets[key].name }
    }
  ]

  bind_allowed_cidrs = [for v in values(var.all_vnets) : v.ip]
  bind_allowed_str   = join("; ", concat(local.bind_allowed_cidrs, ["localhost"]))
}


# =========================================================================
# 3 VM POUR LE DNS
# =========================================================================


resource "xenorchestra_vm" "vm_dns" {

  name_label = "VM-DNS"
  name_description = "VM DNS créée avec Terraform"
  host = var.hosts[ 0 % length(var.hosts) ]

  template = data.xenorchestra_template.debian.id
  cpus       = 1
  memory_max = 4 * 1073741824
  hvm_boot_firmware = "bios"
  network {
      network_id  = var.network_id
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
          defer: true
          content: |
            options {
                directory "/var/cache/bind";
                recursion yes;
                listen-on { any; };
                listen-on-v6 { any; };
                allow-query {${local.bind_allowed_str}; };
                allow-recursion {${local.bind_allowed_str}; };
                allow-transfer { 10.0.10.15; 10.0.10.16; };
                also-notify { 10.0.10.15; 10.0.10.16; };
                forwarders { 8.8.8.8; 1.1.1.1; };
                dnssec-validation auto;
                auth-nxdomain no;
            };
        - path: /etc/bind/named.conf.local
          defer: true
          content: |
            zone "gandal.internal" {
                type master;
                file "/etc/bind/db.gandal.internal";
            };
        - path: /etc/bind/db.gandal.internal
          content: |
            $TTL    604800
            @       IN      SOA     dns-1.gandal.internal. admin.gandal.internal. (
                                              1       ; Serial
                                         604800       ; Refresh
                                          86400       ; Retry
                                        2419200       ; Expire
                                         604800 )     ; Negative Cache TTL
            ;
            @        IN      NS      dns-1.gandal.internal.
            dns-1    IN      A       10.0.10.14
            dns-2    IN      A       10.0.10.15
            dns-3    IN      A       10.0.10.16
            dhcp-1   IN      A       10.0.10.12
            dhcp-2   IN      A       10.0.10.13
            netbox   IN      A       10.0.10.11

      runcmd:
        - systemctl restart bind9
        - systemctl enable bind9
  EOF

  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.10.14/24
            gateway: 10.0.10.1
  EOF	

  disk {
    name_label = "VM-DNS-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}

resource "xenorchestra_vm" "vm_dns2" {

  name_label = "VM-DNS-2"
  name_description = "VM DNS secondaire créée avec Terraform"
  host = var.hosts[ 1 % length(var.hosts) ]

  template = data.xenorchestra_template.debian.id
  cpus       = 1
  memory_max = 4 * 1073741824
  hvm_boot_firmware = "bios"
  network {
      network_id  = var.network_id
  }

  cloud_config = <<-EOF
      #cloud-config
      hostname: VM-DNS-2
      manage_etc_hosts: true

      package_update: true
      packages:
        - bind9
        - bind9utils
        - dnsutils

      write_files:
        - path: /etc/bind/named.conf.options
          defer: true
          content: |
            options {
                directory "/var/cache/bind";
                recursion yes;
                allow-transfer { none; };
                also-notify { none; };
            };
        - path: /etc/bind/named.conf.local
          content: |
            zone "gandal.internal" {
                type slave;
                masters { 10.0.10.14; }
                file "/etc/bind/db.gandal.internal";
            };

      runcmd:
        - systemctl restart bind9
        - systemctl enable bind9
  EOF

  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.10.15/24
            gateway: 10.0.10.1
  EOF	

  disk {
    name_label = "VM-DNS-2-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}
resource "xenorchestra_vm" "vm_dns3" {

  name_label = "VM-DNS-3"
  name_description = "VM DNS secondaire créée avec Terraform"
  host = var.hosts[ 2 % length(var.hosts) ]

  template = data.xenorchestra_template.debian.id
  cpus       = 1
  memory_max = 4 * 1073741824
  hvm_boot_firmware = "bios"
  network {
      network_id  = var.network_id
  }

  cloud_config = <<-EOF
      #cloud-config
      hostname: VM-DNS-3
      manage_etc_hosts: true

      package_update: true
      packages:
        - bind9
        - bind9utils
        - dnsutils

      write_files:
        - path: /etc/bind/named.conf.options
          defer: true
          content: |
            options {
                directory "/var/cache/bind";
                recursion yes;
                allow-transfer { none; };
                also-notify { none; };
            };
        - path: /etc/bind/named.conf.local
          content: |
            zone "gandal.internal" {
                type slave;
                masters { 10.0.10.14; }
                file "/etc/bind/db.gandal.internal";
            };

      runcmd:
        - systemctl restart bind9
        - systemctl enable bind9
  EOF

  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.10.16/24
            gateway: 10.0.10.1
  EOF	

  disk {
    name_label = "VM-DNS-3-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}


# =========================================================================
# 2 VM EN HA POUR LE DHCP
# =========================================================================


resource "xenorchestra_vm" "vm_dhcp1" {

  name_label = "VM-DHCP-1"
  name_description = "VM DHCP créée avec Terraform"
  host = var.hosts[ 3 % length(var.hosts) ]

  template = data.xenorchestra_template.debian.id
  cpus       = 1
  memory_max = 4 * 1073741824
  hvm_boot_firmware = "bios"
  network {
      network_id  = var.network_id
  }

  cloud_config = <<-EOF
      #cloud-config
      hostname: VM-DHCP-1
      manage_etc_hosts: true

      package_update: true
      packages:
        - kea-dhcp4-server
        - kea-admin

      write_files:
        - path: /etc/kea/kea-dhcp4.conf
          defer: true
          content: |
            Dhcp4 = {
              interfaces-config   = { interfaces = ["*"] }
              control-socket      = { "socket-type" = "unix", "socket-name" = "kea4-ctrl-socket" }
              lease-database      = { type = "memfile", "lfc-interval" = 3600 }
              valid-lifetime      = 4000
              subnet4             = ${local.subnets_kea}
              multi-threading: {
                enable-multi-threading: true,
                http-dedicated-listener: true,
                http-listener-threads: 0,
                http-client-threads: 0
              }
              hooks-libraries: [
                {
                  library: "/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_lease_cmds.so"
                },
                {
                  library": "/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_ha.so",
                  parameters: {
                    high-availability: [
                      {
                        this-server-name: "VM-DHCP-1",
                        mode: "hot-standby",
                        heartbeat-delay: 10000,
                        max-response-delay: 60000
                        peers: [
                          {
                            name: "VM-DHCP-1",
                            url: "http://10.0.10.12:8000/",
                            role: "primary",
                            auto-failover: true
                          },
                          {
                            name: "VM-DHCP-2",
                            url: "http://10.0.10.13:8000/",
                            role: "standby",
                            auto-failover: true
                          }
                        ]
                      }
                    ]
                  }
                }
              ]
            }

      runcmd:
        - systemctl restart kea-dhcp4-server
        - systemctl enable kea-dhcp4-server
  EOF

  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.10.12/24
            gateway: 10.0.10.1
  EOF	
  disk {
    name_label = "VM-DHCP1-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}

resource "xenorchestra_vm" "vm_dhcp2" {

  name_label = "VM-DHCP-2"
  name_description = "VM DHCP créée avec Terraform"
  host = var.hosts[ 4 % length(var.hosts) ]

  template = data.xenorchestra_template.debian.id
  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"
  network {
      network_id  = var.network_id
  }

  cloud_config = <<-EOF
      #cloud-config
      hostname: VM-DHCP-2
      manage_etc_hosts: true

      package_update: true
      packages:
        - kea-dhcp4-server
        - kea-admin

      write_files:
        - path: /etc/kea/kea-dhcp4.conf
          defer: true
          content: |
            Dhcp4 = {
              interfaces-config   = { interfaces = ["*"] }
              control-socket      = { "socket-type" = "unix", "socket-name" = "kea4-ctrl-socket" }
              lease-database      = { type = "memfile", "lfc-interval" = 3600 }
              valid-lifetime      = 4000
              subnet4             = ${local.subnets_kea}
              multi-threading: {
                enable-multi-threading: true,
                http-dedicated-listener: true,
                http-listener-threads: 0,
                http-client-threads: 0
              }
              hooks-libraries: [
                {
                  library: "/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_lease_cmds.so"
                },
                {
                  library: "/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_ha.so",
                  parameters: {
                    high-availability: [
                      {
                        this-server-name: "VM-DHCP-2",
                        mode: "hot-standby",
                        peers: [
                          {
                            name: "VM-DHCP-1",
                            url: "http://10.0.10.12:8000/",
                            role: "primary",
                            auto-failover: true
                          },
                          {
                            name: "VM-DHCP-2",
                            url: "http://10.0.10.13:8000/",
                            role: "standby",
                            auto-failover: true
                          }
                        ]
                      }
                    ]
                  }
                }
              ]
            }

      runcmd:
        - systemctl restart kea-dhcp4-server
        - systemctl enable kea-dhcp4-server
  EOF

  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.10.13/24
            gateway: 10.0.10.1
  EOF	
  disk {
    name_label = "VM-DHCP-2-disk"
    sr_id      = data.xenorchestra_sr.sr_local.id
    size       = 10 * 1024 * 1024 * 1024
  }
  
}


# =========================================================================
# 1 VM POUR NETBOX
# =========================================================================


resource "xenorchestra_vm" "vm_netbox" {

  name_label = "VM-NetBox"
  name_description = "VM NetBox créée avec Terraform"
  host = var.hosts[ 5 % length(var.hosts) ]

  template = data.xenorchestra_template.debian.id
  cpus       = 1
  memory_max = 1073741824 # 1 Go
  hvm_boot_firmware = "bios"
  network {
      network_id  = var.network_id
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

  cloud_network_config = <<-EOF
      version: 1
      config:
      - type: physical
        name: enX0
        subnets:
          - type: static
            address: 10.0.10.11/24
            gateway: 10.0.10.1
  EOF	
  disk {
    name_label = "VM-NetBox-disk"
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
output "dns2_id" {
    value = xenorchestra_vm.vm_dns3.id
}
output "dns3_id" {
    value = xenorchestra_vm.vm_dns3.id
}
output "dhcp1_id" {
    value = xenorchestra_vm.vm_dhcp1.id
}
output "dhcp2_id" {
    value = xenorchestra_vm.vm_dhcp2.id
}
output "netbox_id" {
    value = xenorchestra_vm.vm_netbox.id
}