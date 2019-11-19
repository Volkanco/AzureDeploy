# Configure the Microsoft Azure Provider
provider "azurerm" {

}

module "spokesubnet_setup" {
  source            = "../modules/spokesubnet-nonprod"
  AppName=var.AppName
  busunit=var.busunit
  location = var.location 
  spoke_subnet_names=var.spoke_subnet_names
  spoke_subnet_prefixes=var.spoke_subnet_prefixes
  onprem_address_prefix=var.onprem_address_prefix
  hubfwip=var.hubfwip
}


