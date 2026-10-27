locals {
  singlehosts_config_raw = yamldecode(file("${var.config_dir}/single_vm.yaml"))
  proxmox_ve_config = yamldecode(file("${var.config_dir}/proxmox_ve.yaml"))
}

resource "proxmox_download_file" "diskimport_cloudimage_file" {
  for_each = {
    for disk in local.singlehosts_config_raw.import_disks : disk.name => disk
  }
  content_type = "import"
  datastore_id = local.proxmox_ve_config.proxmox_ve_imagestorage
  node_name    = local.proxmox_ve_config.proxmox_ve_hosts[0]
  url          = each.value.import_url
  # need to rename the file to *.qcow2 to indicate the actual file format for import
  file_name = "terraform_${split(".", basename(each.value.import_url))[0]}.qcow2"
}

resource "proxmox_virtual_environment_vm" "single_vm" {
  for_each = local.singlehosts_config_raw.vm

  name = each.value.name
  node_name = local.proxmox_ve_config.proxmox_ve_hosts[0]
  vm_id = each.value.vmid

  tags = concat(
      ["terraform"],
      each.value.tags
    )

  machine     = "q35"
  bios        = "ovmf"

  boot_order = ["scsi0"]

  memory {
      dedicated = each.value.memory
  }
  cpu {
    cores = each.value.cpu
    type = "host"
  }

  dynamic "network_device" {
    for_each = each.value.networks
    content {
      bridge = network_device.value.bridge
    }
  }

  efi_disk {
    datastore_id = local.proxmox_ve_config.proxmox_ve_datastorage
    type         = "4m"
    pre_enrolled_keys = true
  }
  scsi_hardware = "virtio-scsi-single"

  dynamic "disk" {
    for_each = each.value.disks
    content {
      interface = disk.key
      size = disk.value.size
      iothread     = true
      discard      = "on"
      datastore_id = local.proxmox_ve_config.proxmox_ve_datastorage

      import_from = disk.key == "scsi0" ? proxmox_download_file.diskimport_cloudimage_file[disk.value.import_disk].id : null
    }
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  initialization {
    datastore_id = local.proxmox_ve_config.proxmox_ve_datastorage
    dns {
      servers = flatten([each.value.dns.server])
      domain = each.value.dns.domain
    }
    upgrade = true
    dynamic "ip_config" {
      for_each = each.value.networks
      content {
        ipv4 {
            address = ip_config.value.ip
            gateway = try(ip_config.value.gateway, null)
          }
      }
    }
    user_account {
        username = local.singlehosts_config_raw.user.name
        keys = flatten([local.singlehosts_config_raw.user.ssh_key])
    }
  }
}

resource "proxmox_pool_membership" "singlevm_pool_membership" {
  for_each = local.singlehosts_config_raw.vm

  pool_id = each.value.pool
  vm_id   = proxmox_virtual_environment_vm.single_vm[each.key].id
}
