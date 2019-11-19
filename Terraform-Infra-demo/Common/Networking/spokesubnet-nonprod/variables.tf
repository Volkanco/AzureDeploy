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
