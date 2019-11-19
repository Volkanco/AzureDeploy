#############################################################################
# OUTPUTS
#############################################################################

output "vnet_id" {
  value = azurerm_virtual_network.vnet-hub.id
}

output "vnet_name" {
  value = azurerm_virtual_network.vnet-hub.name
}

output "vnet_subnets" {
  value = [azurerm_virtual_network.vnet-hub.subnet]
}
