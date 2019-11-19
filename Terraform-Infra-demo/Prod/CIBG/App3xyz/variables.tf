#############################################################################
# VARIABLES
#############################################################################

variable "resource_group_name" {
  type   = string
}

variable "vnet_name" {
  type   = string 
}

variable "location" {
  type    = string
  }


variable "vnet_cidr_range" {
  type    = string
}


variable "subnet_prefixes" {
  type    = list(string)
}


variable "subnet_names" {
  type    = list(string)
}

variable "dns_servers" {
  type    = list(string)
}

variable "environment" {
  type    = string
}


variable "HubFwIP" {
  type  = string
}

variable "AppName" {
  type  = string
}

variable "hub_sub_id" {
  type = string
}


variable "hub_vnet_name" {
  type = string
}

variable "hub_vnet_id" {
  type = string
}

variable "hub_resource_group" {
  type = string
}

# declared vt -var druing runtime
variable "hub_principal_id" {
  type = string
}

variable "hub_client_id" {
  type = string
}

variable "hub_client_secret" {
  type = string
}

variable "peering_role_def_name" {
  type = string
}


