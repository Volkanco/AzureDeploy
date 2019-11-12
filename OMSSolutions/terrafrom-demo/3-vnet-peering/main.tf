#############################################################################
# VARIABLES
#############################################################################

variable "resource_group_name" {
  type   = string
  default="tf-app1-uaen"
}

variable "vnet_name" {
  type   = string
  default="tf-spokevnet-app1-uaen"
}

variable "location" {
  type    = string
  default = "uaenorth"
}


variable "vnet_cidr_range" {
  type    = string
  default = "10.2.0.0/16"
}


variable "subnet_prefixes" {
  type    = list(string)
  default = ["10.2.0.0/24", "10.2.1.0/24"]
}


variable "subnet_names" {
  type    = list(string)
  default = ["web", "database"]
}

variable "HubFwIP" {
  type  = string
  default = "10.1.2.4"
    
}

variable "AppName" {
  type  = string
    default ="myapp1"
}

#############################################################################
# PROVIDERS
#############################################################################

provider "azurerm" {

}


#############################################################################
# DATA
#############################################################################

data "external" "getCIDR" {
  program = ["bash", "${path.root}/getipcidr.sh"]

  query = {
    rg = "${var.resource_group_name}"
    vnetname = "${var.vnet_name}"
  }
}



resource "null_resource" "post-config" {

  depends_on = [data.external.getCIDR]

  provisioner "local-exec" {
    command = <<EOT
echo "  rg  ${var.resource_group_name}" >> logger.txt
echo " vnetname = ${var.vnet_name}" >> logger.txt
echo "${data.external.getCIDR.result["CIDR"]}"  >>logger.txt
EOT
  }
}




#############################################################################
# RESOURCES
#############################################################################

resource "azurerm_resource_group" "spokerg" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    environment = "PROD"
    costcenter  = var.AppName

  }
}
#data.azurerm_virtual_network.checkvnet ? data.azurerm_virtual_network.checkvnet.address_space : "${data.external.getCIDR.result["CIDR"]}" 
module "vnet-main" {
   #count    = data.azurerm_virtual_network.checkvnet ? 0 : 1
  source              = "Azure/vnet/azurerm"
  resource_group_name = var.resource_group_name
  location            = var.location
  vnet_name           = var.vnet_name
  address_space       = "${data.external.getCIDR.result["CIDR"]}" 
  subnet_prefixes     = [cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 0),cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 1)]
  subnet_names        = var.subnet_names
  nsg_ids             = {}

  tags = {
    environment = "PROD"
    costcenter  = var.AppName

  }
}

/*
# Add Routes 
resource "azurerm_route_table" "ApptoHubRouting" {
  name                          = "${var.AppName}VnettoHubRoutingTable"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  disable_bgp_route_propagation = false

  tags = {
                  environment = "PROD"
                  costcenter  = var.AppName
  }

   depends_on = [azurerm_resource_group.spokerg]
}


resource "azurerm_route" "websubvnetlocal" {
  name                = "websubvnetlocal"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      =  "${cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 1)}"
  next_hop_type       = "vnetlocal"
 }




resource "azurerm_route" "dbsubvnetlocal" {
  name                = "dbsubvnetlocal"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      = "${cidrsubnet(data.external.getCIDR.result["CIDR"], 2, 2)}"
  next_hop_type       = "vnetlocal"
 }

resource "azurerm_route" "AppVnettoPrvtHub" {
  name                = "AppVnettoPrvtHub"
  resource_group_name = var.resource_group_name
  route_table_name    = "${azurerm_route_table.ApptoHubRouting.name}"
  address_prefix      = data.external.getCIDR.result["CIDR"]
  next_hop_type       = "VirtualAppliance"
  next_hop_in_ip_address = var.HubFwIP
}


resource "azurerm_subnet_route_table_association" "websubnetroute" {
  subnet_id      = "${module.vnet-main.vnet_subnets[0]}"
  route_table_id = "${azurerm_route_table.ApptoHubRouting.id}"
}


resource "azurerm_subnet_route_table_association" "bdsubnetroute" {
  subnet_id      = "${module.vnet-main.vnet_subnets[1]}"
  route_table_id = "${azurerm_route_table.ApptoHubRouting.id}"
}

*/
#############################################################################
# OUTPUTS
#############################################################################

output "vnet_id" {
  value = module.vnet-main.vnet_id
}

output "CIDRRange" {
 value = data.external.getCIDR.result["CIDR"]
}
