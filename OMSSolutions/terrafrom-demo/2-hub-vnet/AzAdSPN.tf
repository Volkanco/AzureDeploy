
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

resource "azuread_service_principal_password" "vnet_peering" {
  service_principal_id = azuread_service_principal.vnet_peering.id
  value                = random_password.vnet_peering.result
  end_date_relative    = "17520h"
}

resource "azurerm_role_definition" "vnet-peering" {
  name     = "allow-vnet-peering"
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
  scope              = module.vnet-hub.vnet_id
  role_definition_id = azurerm_role_definition.vnet-peering.id
  principal_id       = azuread_service_principal.vnet_peering.id
}

