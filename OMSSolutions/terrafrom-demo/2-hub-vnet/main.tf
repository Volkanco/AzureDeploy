
#############################################################################
# DATA
#############################################################################

data "azurerm_subscription" "current" {}

#############################################################################
# PROVIDERS
#############################################################################

provider "azurerm" {

}

provider "azuread" {

}

#############################################################################
# RESOURCES
#############################################################################

## NETWORKING ##

resource "azurerm_resource_group" "hub" {
  name     = var.hub_resource_group_name
  location = var.location

  tags = {
    environment = "securityhub"
  }
}

#Add DNS IF needed 

module "vnet-hub" {
  source              = "Azure/vnet/azurerm"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  vnet_name           = azurerm_resource_group.hub.name
  address_space       = var.vnet_cidr_range
  subnet_prefixes     = var.hub_subnet_prefixes
  subnet_names        = var.hub_subnet_names
  nsg_ids             = {}
  dns_servers         =[]
  

  tags = {
    environment = "securityhub"
    costcenter  = "securityhub"

  }
}


# Add NSG's

module "network-security-group-mgmt" {
    source                     = "Azure/network-security-group/azurerm"
    resource_group_name        = azurerm_resource_group.hub.name
    location                   = var.location
    security_group_name        = "AllowMgmt"
    predefined_rules           = [
      {
        name                   = "SSH"
        priority               = "200"
        source_address_prefix  = var.onprem_address_prefix
      },
      {
        name                   = "RDP"
        priority               = "201"
        source_address_prefix  = var.onprem_address_prefix
      }
    ]
    custom_rules               = [
      {
        name                   = "mgmtWeb"
        priority               = "202"
        direction              = "Inbound"
        access                 = "Allow"
        protocol               = "tcp"
        destination_port_range = "8080"
        description            = "SAMPLE NSG Rule for web based management "
        source_address_prefix  = var.onprem_address_prefix
      }
    ]
    tags                       = {
                                    environment = "securityhub"
                                    costcenter  = "securityhub"
                                 }
}



