/*
# Add Routes 
resource "azurerm_route_table" "ApptoHubRouting" {
  name                          = "${var.AppName}VnettoHubRoutingTable"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  disable_bgp_route_propagation = false

  tags = {
                  environment = var.environment
                  costcenter  = var.AppName
  }

   depends_on = [azurerm_resource_group.spokerg]
}


resource "azurerm_route" "appdevsubnetlocal" {
  name                = "${var.AppName}devsubnetlocal"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      =  "${cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 1)}"
  next_hop_type       = "vnetlocal"
 }

resource "azurerm_route" "apptestsubnetlocal" {
  name                = "${var.AppName}testsubnetlocal"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      = "${cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 2)}"
  next_hop_type       = "vnetlocal"
 }

resource "azurerm_route" "appuatsubnetlocal" {
  name                = "${var.AppName}tuatsubnetlocal"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      = "${cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 3)}"
  next_hop_type       = "vnetlocal"
 }

resource "azurerm_route" "appsimsubnetlocal" {
  name                = "${var.AppName}simsubnetlocal"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      = "${cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 4)}"
  next_hop_type       = "vnetlocal"
 }

resource "azurerm_route" "appVnettoPrvtHub" {
  name                = "${var.AppName}VnettoPrvtHub"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      = data.external.getCIDR.result["CIDR"]
  next_hop_type       = "VirtualAppliance"
  next_hop_in_ip_address = var.HubFwIP
}


resource "azurerm_subnet_route_table_association" "devsubnetroute" {
  subnet_id      = "${data.azurerm_virtual_network.vnetspoke[0].vnet_subnets[0]}"
  route_table_id = "${azurerm_route_table.ApptoHubRouting.id}"
}


resource "azurerm_subnet_route_table_association" "testsubnetroute" {
  subnet_id      = "${data.azurerm_virtual_network.vnetspoke[0].vnet_subnets[1]}"
  route_table_id = "${azurerm_route_table.ApptoHubRouting.id}"
}


resource "azurerm_subnet_route_table_association" "uatsubnetroute" {
  subnet_id      = "${data.azurerm_virtual_network.vnetspoke[0].vnet_subnets[2]}"
  route_table_id = "${azurerm_route_table.ApptoHubRouting.id}"
}


resource "azurerm_subnet_route_table_association" "simsubnetroute" {
  subnet_id      = "${data.azurerm_virtual_network.vnetspoke[0].vnet_subnets[3]}"
  route_table_id = "${azurerm_route_table.ApptoHubRouting.id}"
}

*/
