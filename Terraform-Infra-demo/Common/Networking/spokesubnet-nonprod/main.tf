
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
  spokevnet="vnet-spoke-${local.resource_suffix}"
}



#############################################################################
# RESOURCES
#############################################################################


data "azurerm_virtual_network"  "vnetspoke" {
  name                = "${local.spokevnet}"
  resource_group_name = "${local.spokerg}"
}



resource "azurerm_subnet" "appsubnets" {
  count                = "${length(var.spoke_subnet_names)}"
  name                 = "${var.AppName}${element(var.spoke_subnet_names, count.index)}"
  resource_group_name  = "${local.spokerg}"
  virtual_network_name = "${data.azurerm_virtual_network.vnetspoke.name}"
  address_prefix       = "${element(var.spoke_subnet_prefixes, count.index)}" 
}

