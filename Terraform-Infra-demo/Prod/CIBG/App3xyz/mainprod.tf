# Configure the Microsoft Azure Provider
provider "azurerm" {

}


module "spokeprodvnet_setup" {
  source            = "../modules/spokenvnet-prod"
  AppName=var.AppName
  peering_role_def_name=var.peering_role_def_name
  resource_group_name=var.resource_group_name
  vnet_name =var.vnet_name
  vnet_cidr_range=var.vnet_cidr_range
  location = var.location 
  environment=var.environment
  dns_servers=var.dns_servers
  subnet_names=var.subnet_names
  subnet_prefixes=var.subnet_prefixes
  HubFwIP = var.HubFwIP
  hub_sub_id=var.hub_sub_id
  hub_vnet_name=var.hub_vnet_name
  hub_vnet_id=var.hub_vnet_id
  hub_resource_group=var.hub_resource_group
  hub_client_id=var.hub_client_id
  hub_principal_id=var.hub_principal_id
  hub_client_secret=var.hub_client_secret
}




#Add NSG Rules as needed 
resource "azurerm_network_security_rule" "HubFwInbound" {
  name                        = "HubFwInbound-${var.AppName}"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "${var.hubfwip}"
  destination_address_prefix  = "[${spokeprodvnet_setup.vnet_subnets_address_prefix},]" 
  resource_group_name         = "[${spokeprodvnet_setup.resource_group_name}"
  network_security_group_name = "${spokeprodvnet_setup.nsg_name}"
}

