#############################################################################
# OUTPUTS
#############################################################################

output "vnet_id" {
  value = azurerm_virtual_network.vnet-spoke.id
}

output "vnet_name" {
  value = azurerm_virtual_network.vnet-spoke.name
}

output "vnet_subnets" {
  value = [azurerm_virtual_network.vnet-spoke.subnet]
}

output "vnet_subnets_address_prefix" {
  value = [azurerm_subnet.msintsubnets.*.address_prefix]
}

output "nsg_name" {
  value = azurerm_network_security_group.spokensg.name
}


output "resource_group_name" {
  value = azurerm_resource_group.spoke.name
}



