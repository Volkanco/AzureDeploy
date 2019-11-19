#############################################################################
# VARIABLES
#############################################################################


variable "AppName" {
  type  = string
}


variable "busunit" {
  type    = string
}

variable "location" {
  type    = string
}


variable "hub_private_rg" {
  type    = string
}

variable "hub_private_vnet" {
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

variable "spoke_subnet_prefixes" {
  type    = list(string)
}

variable "spoke_subnet_names" {
  type    = list(string)
}

variable "onprem_address_prefix" {
    type    = string
}

variable "hubfwip" {
    type    = string
}



variable "tags" {
  type = "map"
}


variable "dns_servers" {
  type    = list(string)
}


/*
used for static naming , not use danymore
variable "hub_resource_group_name" {
  type    = string
}

variable "vnet_name" {
  type    = string
}
*/
