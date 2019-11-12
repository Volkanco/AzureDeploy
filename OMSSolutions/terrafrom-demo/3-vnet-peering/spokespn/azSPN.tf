#############################################################################
# VARIABLES
#############################################################################


variable "resource_group_name" {
  type   = string
  default="tf-spoke-app1-uaen"
}

variable "location" {
  type    = string
  default = "uaenorth"
}



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

data "azurerm_virtual_network" "checkvnet" {
  name                = var.resource_group_name
  resource_group_name = var.resource_group_name
}


## AZURE AD SP ##

resource "random_password" "vnet_peering" {
  length  = 16
  special = true
}

resource "azuread_application" "vnet_peering" {
  name = "vnet-peer"
}

resource "azuread_service_principal" "vnet_peering" {
  application_id = azuread_application.vnet_peering.application_id
}

resource "azuread_service_principal_password" "vnet_peering_spoke" {
  service_principal_id = azuread_service_principal.vnet_peering.id
  value                = random_password.vnet_peering.result
  end_date_relative    = "17520h"
}

resource "azurerm_role_definition" "vnet-peering-spoke" {
  name     = "allow-vnet-peering-spoke"
  scope    = data.azurerm_subscription.current.id

  permissions {
    actions     = ["Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write", "Microsoft.Network/virtualNetworks/peer/action", "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/read", "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/delete"]
    not_actions = []
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id,
  ]
}

resource "azurerm_role_assignment" "vnet" {
  scope              = data.azurerm_virtual_network.checkvnet.id
  role_definition_id = azurerm_role_definition.vnet-peering-spoke.id
  principal_id       = azuread_service_principal.vnet_peering_spoke.id
}

resource "null_resource" "post-config" {

  depends_on = [azurerm_role_assignment.vnet]

  provisioner "local-exec" {
    command = <<EOT
echo "export TF_VAR_spoke_vnet_id=${data.azurerm_virtual_network.checkvnet.id}" >> spoke-next-step.txt
echo "export TF_VAR_spoke_vnet_name=${var.resource_group_name}" >> spoke-next-step.txt
echo "export TF_VAR_spoke_sub_id=${data.azurerm_subscription.current.subscription_id}" >> spoke-next-step.txt
echo "export TF_VAR_spoke_client_id=${azuread_service_principal.vnet_peering.application_id}" >> spoke-next-step.txt
echo "export TF_VAR_spoke_principal_id=${azuread_service_principal.vnet_peering.id}" >> spoke-next-step.txt
echo "export TF_VAR_spoke_client_secret='${random_password.vnet_peering.result}'" >> spoke-next-step.txt
echo "export TF_VAR_spoke_resource_group=${var.resource_group_name}" >> spoke-next-step.txt
EOT
  }
}

#############################################################################
# OUTPUTS
#############################################################################

output "vnet_id" {
  value = module.vnet-hub.vnet_id
}

output "vnet_name" {
  value = module.vnet-hub.vnet_name
}

output "vnet_subnets" {
  value = module.vnet-hub.vnet_subnets
}


output "service_principal_client_id" {
  value = azuread_service_principal.vnet_peering.id
}

output "service_principal_client_secret" {
  value = random_password.vnet_peering.result
}

output "resource_group_name" {
  value = azurerm_resource_group.sec.name
}

