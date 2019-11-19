# Configure the Microsoft Azure Provider
provider "azurerm" {

}

# RG naming will be  rg-hub-{busunit}-{ShortLocation}

module "prod_hub_setup" {
  source            = "../modules/hub-prod"
  busunit=var.busunit
  location = var.location 
  vnet_cidr_range=var.vnet_cidr_range
  hub_subnet_prefixes=var.hub_subnet_prefixes
  hub_subnet_names=var.hub_subnet_names
  onprem_address_prefix=var.onprem_address_prefix
  tags=var.tags
  dns_servers=var.dns_servers
}


