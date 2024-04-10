terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
    }
  }

  required_version = ">= 0.14.9"
}



resource "azurerm_public_ip" "appgw" {
  name                = "appgw-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static" #Dynamic
}

# since these variables are re-used - a locals block makes this more maintainable
 locals {
   backend_address_pool_name      = "${var.vnet_name}-beap"
   frontend_port_name             = "${var.vnet_name}-feport"
   frontend_ip_configuration_name = "${var.vnet_name}-feip"
   http_setting_name              = "${var.vnet_name}-be-htst"
   listener_name                  = "${var.vnet_name}-httplstn"
   request_routing_rule_name      = "${var.vnet_name}-rqrt"
   #app_gateway_subnet_name        = data.azurerm_subnet.appgwsubnet.name
 }


 resource "azurerm_application_gateway" "network" {
   name                = var.app_gateway_name
   resource_group_name = var.resource_group_name
   location            = var.location

   sku {
     name     = var.app_gateway_sku
     tier     = var.app_gateway_tier
     capacity = 2
   }

   gateway_ip_configuration {
     name      = "appGatewayIpConfig"
     subnet_id = var.appgw_subnet_id
   }

   frontend_port {
     name = local.frontend_port_name
     port = 80
   }

   frontend_port {
     name = "httpsPort"
     port = 443
   }

   frontend_ip_configuration {
     name                 = local.frontend_ip_configuration_name
     public_ip_address_id = azurerm_public_ip.appgw.id
   }

   backend_address_pool {
     name = local.backend_address_pool_name
   }

   backend_http_settings {
     name                  = local.http_setting_name
     cookie_based_affinity = "Disabled"
     port                  = 80
     protocol              = "Http"
     request_timeout       = 1
   }

   http_listener {
     name                           = local.listener_name
     frontend_ip_configuration_name = local.frontend_ip_configuration_name
     frontend_port_name             = local.frontend_port_name
     protocol                       = "Http"
   }

   request_routing_rule {
     name                       = local.request_routing_rule_name
     rule_type                  = "Basic"
     http_listener_name         = local.listener_name
     backend_address_pool_name  = local.backend_address_pool_name
     backend_http_settings_name = local.http_setting_name
     priority                   = 100
   }

   tags = var.tags

   depends_on = [azurerm_public_ip.appgw]

   lifecycle {
     ignore_changes = [
       backend_address_pool,
       backend_http_settings,
       request_routing_rule,
       http_listener,
       probe,
       tags,
       frontend_port
     ]
   }
 }


 #https://saumyapandey.hashnode.dev/aks-with-application-gateway-agic-using-terraform
 #grant agic permission to operate  appgw network, agggw and resource group
 resource "azurerm_role_assignment" "Network_Contributor_subnet" {
   scope                = var.appgw_subnet_id
   role_definition_name = "Network Contributor"
   principal_id         = var.agrc_object_id
   #principal_id         = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
   
 }

 resource "azurerm_role_assignment" "rg_reader" {
   scope                = var.resource_group_id
   role_definition_name = "Reader"
   principal_id         = var.agrc_object_id
 }

 resource "azurerm_role_assignment" "app-gw-contributor" {
   scope                = var.app_gateway_id
   role_definition_name = "Contributor"
   principal_id         = var.agrc_object_id
 }
