/*
resource "azurerm_management_lock" "resource-group-level" {
  name       = "Lock ${azurerm_resource_group.spoke.name}"
  scope      = "${azurerm_resource_group.spoke.id}"
  lock_level = "CanNotDelete"
  notes      = "CanNotDelete  this resource group"
}


*/

