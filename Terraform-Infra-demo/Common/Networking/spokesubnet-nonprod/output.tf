
#############################################################################
# OUTPUTS
#############################################################################


output "subnets" {
 value = "${join(",", azurerm_subnet.appsubnets.*.id)}"
}

output "subnetLists" {
 value = ["${azurerm_subnet.appsubnets.*.id}"]
}
