variable "hub_sub_id" {
  type = string
}

variable "hub_client_id" {
  type = string
}

variable "hub_client_secret" {
  type = string
}

variable "hub_vnet_name" {
  type = string
}

variable "hub_vnet_id" {
  type = string
}

variable "hub_resource_group" {
  type = string
}

variable "hub_principal_id" {
  type = string
}


data "azurerm_subscription" "current" {}


provider "azurerm" {
  alias           = "security"
  subscription_id = var.hub_sub_id
  client_id       = var.hub_client_id
  client_secret   = var.hub_client_secret
  skip_provider_registration  = true
  skip_credentials_validation = true
}

provider "azurerm" {
  alias                       = "peering"
  subscription_id             = data.azurerm_subscription.current.subscription_id
  client_id                   = var.hub_client_id
  client_secret               = var.hub_client_secret
  skip_provider_registration  = true
  skip_credentials_validation = true
}

resource "azurerm_role_definition" "vnet-peering" {
  name  = "allow-vnet-peer-spoke-${var.AppName}"
  scope = data.azurerm_subscription.current.id

  permissions {
    actions     = ["Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write", "Microsoft.Network/virtualNetworks/peer/action", "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/read", "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/delete"]
    not_actions = []
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id,
  ]
}

resource "azurerm_role_assignment" "vnet" {
  scope              = module.vnet-main.vnet_id
  role_definition_id = azurerm_role_definition.vnet-peering.id
  principal_id       = var.hub_principal_id
}

resource "azurerm_virtual_network_peering" "main" {
  name                      = "main_2_sec"
  resource_group_name       = var.resource_group_name
  virtual_network_name      = module.vnet-main.vnet_name
  remote_virtual_network_id = var.hub_vnet_id
  provider                  = azurerm.peering

  depends_on = [azurerm_role_assignment.vnet]
}

resource "azurerm_virtual_network_peering" "sec" {
  name                      = "hub_2_main"
  resource_group_name       = var.hub_resource_group
  virtual_network_name      = var.hub_vnet_name
  remote_virtual_network_id = module.vnet-main.vnet_id
  provider                  = azurerm.security

  depends_on = [azurerm_role_assignment.vnet]
}