
data "azurerm_virtual_network" "hub" {
  name                = "${var.hub_private_vnet}"
  resource_group_name = "${var.hub_private_rg}"
}

resource "azurerm_virtual_network_peering" "tohub" {
  name                      = "${azurerm_virtual_network.vnet-spoke.name}_2_${var.hub_private_vnet}"
  resource_group_name       = "${azurerm_resource_group.spoke.name}"
  virtual_network_name      = "${azurerm_virtual_network.vnet-spoke.name}"
  remote_virtual_network_id = "${data.azurerm_virtual_network.hub.id}"
}

resource "azurerm_virtual_network_peering" "tospoke" {
    
  name                      = "${var.hub_private_vnet}_2_${azurerm_virtual_network.vnet-spoke.name}"
  resource_group_name       = "${var.hub_private_rg}"
  virtual_network_name      = "${var.hub_private_vnet}"
  remote_virtual_network_id = "${azurerm_virtual_network.vnet-spoke.id}"

} 