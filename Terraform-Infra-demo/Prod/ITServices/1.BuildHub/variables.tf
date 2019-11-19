#############################################################################
# VARIABLES
#############################################################################

variable "busunit" {
  type    = string
}

variable "location" {
  type    = string
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

