#############################################################################
# PROVISIONERS
#############################################################################

resource "null_resource" "post-config" {

  depends_on = [azurerm_role_assignment.vnet]

  provisioner "local-exec" {
    command = <<EOT
echo "export TF_VAR_hub_vnet_id=${module.vnet-hub.vnet_id}" >> next-step.txt
echo "export TF_VAR_hub_vnet_name=${module.vnet-hub.vnet_name}" >> next-step.txt
echo "export TF_VAR_hub_sub_id=${data.azurerm_subscription.current.subscription_id}" >> next-step.txt
echo "export TF_VAR_hub_client_id=${azuread_service_principal.vnet_peering.application_id}" >> next-step.txt
echo "export TF_VAR_hub_principal_id=${azuread_service_principal.vnet_peering.id}" >> next-step.txt
echo "export TF_VAR_hub_client_secret='${random_password.vnet_peering.result}'" >> next-step.txt
echo "export TF_VAR_hub_resource_group=${azurerm_resource_group.hub.name}" >> next-step.txt
EOT
  }
}
