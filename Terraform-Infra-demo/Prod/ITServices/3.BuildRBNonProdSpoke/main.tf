# Configure the Microsoft Azure Provider
provider "azurerm" {

}



# RG naming will be  rg-spoke-{busunit}-{ShortLocation}

module "prod_spoke_setup" {
  source            = "./../../Common/Networking/spokevnet-nonprod"
  busunit=var.busunit
  location = var.location 
    hub_private_rg=var.hub_private_rg
  hub_private_vnet=var.hub_private_vnet
  vnet_cidr_range=var.vnet_cidr_range
  spoke_subnet_prefixes=var.spoke_subnet_prefixes
  spoke_subnet_names=var.spoke_subnet_names
  onprem_address_prefix=var.onprem_address_prefix
  tags=var.tags
  dns_servers=var.dns_servers
}


