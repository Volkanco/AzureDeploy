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
