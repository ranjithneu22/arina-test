locals {
  utc_time = timestamp()
  additional_time  = timeadd(local.utc_time, "1h30m")
  tags = {
    environment = "${var.envi}-Environment"
  }
  resource_group_name = "${var.envi}-Resource-Group"
  host_pool_name = "${var.envi}-Host-Pool"
}


data "azurerm_resources" "host_pool" {
  type     = "Microsoft.DesktopVirtualization/hostpools"
  name     = local.host_pool_name
  resource_group_name = local.resource_group_name
}

data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_rg
}

resource "azurerm_network_interface" "avd_vm_nic" {
  count               = var.rdsh_count
  name                = "${var.envi}-${count.index + 1}-nic"
  resource_group_name = local.resource_group_name
  location            = var.resource_group_location

  ip_configuration {
    name                          = "${var.envi}-nic${count.index + 1}_config"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
   tags     = merge(local.tags, tomap({ Created_Time = formatdate("DD-MM-YYYY hh:mm:ss ZZZ", timestamp()) }))
  lifecycle { ignore_changes = [tags["Created_Time"]] }
}

resource "azurerm_windows_virtual_machine" "avd_vm" {
  count                 = var.rdsh_count
  name                  = "${var.envi}-${count.index + 1}"
  resource_group_name   = local.resource_group_name
  location            = var.resource_group_location
  size                  = var.vm_size
  network_interface_ids = ["${azurerm_network_interface.avd_vm_nic.*.id[count.index]}"]
  # azurerm_windows_virtual_machine.avd_vm.*.id[count.index]
  provision_vm_agent    = true
  admin_username        = var.local_admin_username
  admin_password        = var.local_admin_password

  os_disk {
    name                 = "${lower(var.envi)}-${count.index + 1}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = var.offer
    sku       = var.sku
    version   = "latest"
  }
   tags     = merge(local.tags, tomap({ Created_Time = formatdate("DD-MM-YYYY hh:mm:ss ZZZ", timestamp()) }))
  lifecycle { ignore_changes = [tags["Created_Time"]] }

  depends_on = [

    azurerm_network_interface.avd_vm_nic
  ]
}


resource "azurerm_virtual_desktop_host_pool_registration_info" "hostpool_reginfo" {
  hostpool_id     = replace(data.azurerm_resources.host_pool.resources[0].id, "/hostpools", "/hostPools")
   expiration_date = local.additional_time
}


resource "azurerm_virtual_machine_extension" "domain_join" {
  count                      = var.rdsh_count
  name                       = "Extenstion--domainJoin"
  virtual_machine_id         = azurerm_windows_virtual_machine.avd_vm.*.id[count.index]
  publisher = "Microsoft.Compute"
type = "JsonADDomainExtension"
type_handler_version = "1.3"
settings = <<SETTINGS
{
"Name": "${var.domain_name}",
"User": "${var.domain_user_upn}",
"Restart": "true",
"Options": "3"
}
SETTINGS
protected_settings = <<PROTECTED_SETTINGS
{
"Password": "${var.domain_password}"
}
PROTECTED_SETTINGS
depends_on = [
    azurerm_windows_virtual_machine.avd_vm
  ]
}


  

resource "azurerm_virtual_machine_extension" "vmext_dsc" {
  count                      = var.rdsh_count
  name                       = "Extenstion--avd_dsc"
  virtual_machine_id         =  azurerm_windows_virtual_machine.avd_vm.*.id[count.index]
  publisher                  = "Microsoft.Powershell"
  type                       = "DSC"
  type_handler_version       = "2.73"
  auto_upgrade_minor_version = true
settings = <<-SETTINGS
    {
      "modulesUrl": "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_3-10-2021.zip",
      "configurationFunction": "Configuration.ps1\\AddSessionHost",
      "properties": {
        "HostPoolName":"${data.azurerm_resources.host_pool.resources[0].name}"
      }
    }
SETTINGS
  protected_settings = <<PROTECTED_SETTINGS
  {
    "properties": {
      "registrationInfoToken": "${azurerm_virtual_desktop_host_pool_registration_info.hostpool_reginfo.token}"
    }
  }
PROTECTED_SETTINGS
  depends_on = [
    azurerm_virtual_machine_extension.domain_join
  ]
}



