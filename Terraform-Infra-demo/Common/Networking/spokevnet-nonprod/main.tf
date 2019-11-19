#############################################################################
# DATA
#############################################################################

data "azurerm_subscription" "current" {}


####################
# LOCALS
####################

locals {
  resource_suffix = "nonprod-${lower(var.busunit)}-${var.location_short["${var.location}"]}"
  spokerg = "rg-spoke-${local.resource_suffix}"
}


#############################################################################
# RESOURCES
#############################################################################




## NETWORKING ##

resource "azurerm_resource_group" "spoke" {
  name     = "${local.spokerg}"
  location = var.location

  tags = "${var.tags}"
}

#VNET and Subnets


resource "azurerm_virtual_network" "vnet-spoke" {
  name                = "vnet-spoke-${local.resource_suffix}"
  location            = "${var.location}"
  resource_group_name = "${azurerm_resource_group.spoke.name}"
  address_space       = [var.vnet_cidr_range]
  dns_servers         = var.dns_servers

  tags = "${var.tags}"
}


resource "azurerm_subnet" "msintsubnets" {
  count                = "${length(var.spoke_subnet_names)}"
  name                 = "${element(var.spoke_subnet_names, count.index)}"
  resource_group_name  = "${azurerm_resource_group.spoke.name}"
  virtual_network_name = "${azurerm_virtual_network.vnet-spoke.name}"
  address_prefix       = "${element(var.spoke_subnet_prefixes, count.index)}" 
}



