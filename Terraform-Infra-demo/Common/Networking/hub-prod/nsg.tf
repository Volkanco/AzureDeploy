
# Add NSG's

resource "azurerm_network_security_group" "mgmtnsg" {
  name                = "nsg-mgmt-${local.resource_suffix}"
  location            = "${var.location}"
  resource_group_name = "${azurerm_resource_group.hub.name}"

  tags = "${var.tags}"
}

# Associate NSG

resource "azurerm_subnet_network_security_group_association" "hubmgmt" {
  subnet_id                 = "${azurerm_subnet.msintsubnets.*.id[2]}"  
  network_security_group_id = "${azurerm_network_security_group.mgmtnsg.id}"

     depends_on = [azurerm_subnet.msintsubnets]
}

# Associate NSG

resource "azurerm_subnet_network_security_group_association" "hubshared" {
  subnet_id                 = "${azurerm_subnet.msintsubnets.*.id[3]}" 
  network_security_group_id = "${azurerm_network_security_group.mgmtnsg.id}"

  depends_on = [azurerm_subnet.msintsubnets]
}


#Add NSG Rules
resource "azurerm_network_security_rule" "rdprule" {
  name                        = "rdp_rule"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "${var.onprem_address_prefix}"
  destination_address_prefix  = "${azurerm_subnet.msintsubnets[2].address_prefix}"
  resource_group_name         = "${azurerm_resource_group.hub.name}"
  network_security_group_name = "${azurerm_network_security_group.mgmtnsg.name}"
}

resource "azurerm_network_security_rule" "sshrule" {
  name                        = "ssh_rule"
  priority                    = 201
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "${var.onprem_address_prefix}"
  destination_address_prefix  = "${azurerm_subnet.msintsubnets[2].address_prefix}"
  resource_group_name         = "${azurerm_resource_group.hub.name}"
  network_security_group_name = "${azurerm_network_security_group.mgmtnsg.name}"
}

