# Configure the Microsoft Azure Provider
provider "azurerm" {

}


module "spokeprodvnet_setup" {
  source            = "../../../Common/Networking/spokevnet-prod"
  AppName=var.AppName
  busunit=var.busunit
  location = var.location 
  hub_private_rg=var.hub_private_rg
  hub_private_vnet=var.hub_private_vnet
  vnet_cidr_range=var.vnet_cidr_range
  spoke_subnet_prefixes=var.spoke_subnet_prefixes
  spoke_subnet_names=var.spoke_subnet_names
  onprem_address_prefix=var.onprem_address_prefix
  hubfwip=var.hubfwip
  dns_servers=var.dns_servers
  tags=var.tags
 
}


#Add NSG Rules as needed 
/*
resource "azurerm_network_security_rule" "HubFwInbound" {
  name                        = "HubFwInbound-${var.AppName}"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "${var.hubfwip}"
  destination_address_prefix  = "${element(module.spokeprodvnet_setup.vnet_subnets_address_prefix,0)}," 
  resource_group_name         = "[${module.spokeprodvnet_setup.resource_group_name}"
  network_security_group_name = "${module.spokeprodvnet_setup.nsg_name}"
}

*/