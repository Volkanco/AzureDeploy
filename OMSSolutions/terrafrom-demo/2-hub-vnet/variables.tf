#############################################################################
# VARIABLES
#############################################################################

variable "hub_resource_group_name" {
  type    = string
  default = "tf-uae-vnet-hub"
}

variable "location" {
  type    = string
  default = "uaenorth"
}

variable "vnet_cidr_range" {
  type    = string
  default = "10.1.0.0/16"
}

variable "hub_subnet_prefixes" {
  type    = list(string)
  default = ["10.1.1.0/28","10.1.2.0/26", "10.1.3.0/27", "10.1.4.0/24"]
}

variable "hub_subnet_names" {
  type    = list(string)
  default = ["gateway","AzureFirewallSubnet","jumpbox","shared"]
}

variable "onprem_address_prefix" {
    type    = string
    default = "*"  ### Mofidfy woth on prem address range 
  
}

variable "HubFwIP" {
  type  = string
  default ="10.1.2.4"  
}
