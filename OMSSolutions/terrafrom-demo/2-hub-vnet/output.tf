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
  value = azurerm_resource_group.hub.name
}

