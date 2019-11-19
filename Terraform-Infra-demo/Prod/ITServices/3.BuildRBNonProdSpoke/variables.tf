#############################################################################
# VARIABLES
#############################################################################

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

