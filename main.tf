terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~>2.9.7"
    }
  }
}

provider "proxmox" {
  pm_api_url          = "https://192.168.11.22:8006/api2/json"
  pm_api_token_id     = "root@pam!nodir"
  pm_api_token_secret = "da0a6d52-4991-42c3-9e3e-58b004c74adb"
  pm_tls_insecure     = true
}

# Variables for customization
variable "container_count" {
  type    = number
  default = 3
}

variable "container_id" {
  type    = number
  default = 600
}

variable "rootfs_size" {
  type    = string
  default = "10G"
}

variable "container_password" {
  type    = string
  default = "12345"
}

variable "network_config" {
  type = object({
    ip_start = number
    gateway  = string
  })
  default = {
    ip_start = 251
    gateway  = "192.168.11.1"
  }
}

# 1: create containers
resource "proxmox_lxc" "my_container" {
  count        = var.container_count
  vmid         = var.container_id + count.index
  hostname     = format("terraform-container-%d", count.index + 1)
  target_node  = "pve"
  ostemplate   = "Data:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
  cores        = 2
  memory       = 2048

  rootfs {
    storage = "Data"
    size    = var.rootfs_size
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = format("192.168.11.%d/24", var.network_config.ip_start + count.index)
    gw     = var.network_config.gateway
  }

  password        = var.container_password
  ssh_public_keys = file("~/.ssh/id_rsa.pub")

  # Start the container after creation
  provisioner "local-exec" {
    command = <<EOT
      curl -s -k -X POST -H 'Authorization: PVEAPIToken=root@pam!nodir=da0a6d52-4991-42c3-9e3e-58b004c74adb' https://192.168.11.22:8006/api2/json/nodes/pve/lxc/${var.container_id + count.index}/status/start || echo "Failed to start container ${var.container_id + count.index}"
    EOT
  }
}

# 2: set up ssh and user
resource "null_resource" "setup_ssh" {
  count = var.container_count

  connection {
    type        = "ssh"
    user        = "root"
    password    = var.container_password
    host        = format("192.168.11.%d", var.network_config.ip_start + count.index)
    private_key = file("~/.ssh/id_rsa")
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done", # Wait for apt lock
      "apt-get update",
      "apt-get install -y openssh-server sudo",
      "systemctl enable ssh",
      "systemctl start ssh",
      "useradd -m -s /bin/bash user2",
      "echo 'user2:password123' | chpasswd",
      "usermod -aG sudo user2",
      "mkdir -p /home/user2/.ssh",
      "chmod 700 /home/user2/.ssh",
      "echo '${file("~/.ssh/id_rsa.pub")}' > /home/user2/.ssh/authorized_keys",
      "chmod 600 /home/user2/.ssh/authorized_keys",
      "chown -R user2:user2 /home/user2/.ssh",
      "echo 'user2 ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/user2"
    ]
  }

  depends_on = [proxmox_lxc.my_container]
}

# 3: ansible playbook
resource "null_resource" "run_ansible" {
  count = var.container_count

  provisioner "local-exec" {
    command = <<EOT
    ansible-playbook -i /media/nodir/'Новый том'/terraform/terraform/tla2/ansible_inventory/hosts /media/nodir/'Новый том'/terraform/terraform/tla2/ansible/nginx.yml --private-key ~/.ssh/id_rsa --user=user2 --ssh-extra-args='-o StrictHostKeyChecking=no'
    EOT
  }

  depends_on = [null_resource.setup_ssh]
}

# Output Container IPs
output "container_ips" {
  value = [for container in proxmox_lxc.my_container : container.network[0].ip]
}