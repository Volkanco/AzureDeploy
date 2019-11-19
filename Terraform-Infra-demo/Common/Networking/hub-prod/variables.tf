#############################################################################
# VARIABLES
#############################################################################

variable "busunit" {
  type    = string
}

variable "location" {
  type    = string
}

variable "location_short" {
  type = "map"
default = {
    westeurope   = "weu"
    uaenorth    = "uaen"
    uaecentral    = "uaec"
    eastasia      = "eas"
    southeastasia     = "seas"
    eastus      = "eus"
    eastus2      = "eus2"
    northeurope      = "neu"
  }
}

variable "vnet_cidr_range" {
  type    = string
}

variable "hub_subnet_prefixes" {
  type    = list(string)
}

variable "hub_subnet_names" {
  type    = list(string)
}

variable "onprem_address_prefix" {
    type    = string
}

variable "tags" {
  type = "map"
}


variable "dns_servers" {
  type    = list(string)
}

/*
for static naming -not used anyome  
variable "hub_resource_group_name" {
  type    = string
}

variable "vnet_name" {
  type    = string
}
*/