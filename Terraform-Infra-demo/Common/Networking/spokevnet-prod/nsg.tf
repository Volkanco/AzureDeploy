
# Add NSG's

resource "azurerm_network_security_group" "spokensg" {
  name                = "nsg-mgmt-${local.resource_suffix}"
  location            = "${var.location}"
  resource_group_name = "${azurerm_resource_group.spoke.name}"

  tags = "${var.tags}"
}

# Associate NSG

resource "azurerm_subnet_network_security_group_association" "nsg1" {
  count                = "${length(var.spoke_subnet_names)}"
  subnet_id                 = "${element(azurerm_subnet.msintsubnets.*.id,count.index)}"  
  network_security_group_id = "${azurerm_network_security_group.spokensg.id}"

     depends_on = [azurerm_subnet.msintsubnets]
}

/*

##############Moved to parent resource
#Add NSG Rules
resource "azurerm_network_security_rule" "HubFwInbound" {
  count                = "${length(var.spoke_subnet_names)}"
  name                        = "HubFwInbound-${element(var.spoke_subnet_names,count.index)}"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "${var.hubfwip}"
  destination_address_prefix  = "${element(azurerm_subnet.msintsubnets.*.address_prefix,count.index)}" 
  resource_group_name         = "${azurerm_resource_group.spoke.name}"
  network_security_group_name = "${azurerm_network_security_group.spokensg.name}"
}
*/

