
variable "location" {
  description = "Specifies the location for the resource group and all the resources"
  default     = "northeurope"
  type        = string
}

variable "resource_group_name" {
  description = "Specifies the resource group name"
  default     = "BaboRG"
  type        = string
}

variable "resource_group_id" {
  description = "Specifies the resource group id"
  type        = string
}


 variable "app_gateway_name" {
   description = "Name of the Application Gateway"
   default     = "ApplicationGateway1"
 }

 variable "app_gateway_sku" {
   description = "Name of the Application Gateway SKU"
   default     = "Standard_v2"
 }

 variable "app_gateway_tier" {
   description = "Tier of the Application Gateway tier"
   default     = "Standard_v2"
 }

 variable "appgw_subnet_id" {
  description = "The ID of a Subnet where the application gateway should exist. Changing this forces a new resource to be created."
  type        = string
}

 variable "app_gateway_id" {
  description = "The ID of appgw"
  type        = string
}

 variable "tags" {
   type = map(string)

   default = {
     source = "terraform"
   }
 }

 variable "agrc_object_id"{
  description = "The object id of AGIC"
  type = string
 }



