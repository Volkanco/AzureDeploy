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
