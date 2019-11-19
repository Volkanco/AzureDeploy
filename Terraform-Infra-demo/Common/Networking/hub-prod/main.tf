#############################################################################
# DATA
#############################################################################

data "azurerm_subscription" "current" {}


####################
# LOCALS
####################


locals {
  resource_suffix = "${lower(var.busunit)}-${var.location_short["${var.location}"]}"
  hubrg = "rg-hub-${local.resource_suffix}"
}


#############################################################################
# RESOURCES
#############################################################################




## NETWORKING ##

resource "azurerm_resource_group" "hub" {
  name     = "${local.hubrg}"
  location = var.location

  tags = "${var.tags}"
}

#VNET and Subnets


resource "azurerm_virtual_network" "vnet-hub" {
  name                = "vnet-hub-${local.resource_suffix}"
  location            = "${var.location}"
  resource_group_name = "${azurerm_resource_group.hub.name}"
  address_space       = [var.vnet_cidr_range]
  dns_servers         = var.dns_servers

  tags = "${var.tags}"
}


resource "azurerm_subnet" "msintsubnets" {
  count                = "${length(var.hub_subnet_names)}"
  name                 = "${element(var.hub_subnet_names, count.index)}"
  resource_group_name  = "${azurerm_resource_group.hub.name}"
  virtual_network_name = "${azurerm_virtual_network.vnet-hub.name}"
  address_prefix       = "${element(var.hub_subnet_prefixes, count.index)}" 
}



