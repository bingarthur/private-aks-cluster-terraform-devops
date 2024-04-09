terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
    }
  }

  required_version = ">= 0.14.9"
}

resource "azurerm_storage_account" "storage_account" {
  name                = var.name
  resource_group_name = var.resource_group_name

  location                 = var.location
  account_kind             = var.account_kind
  account_tier             = var.account_tier
  account_replication_type = var.replication_type
  is_hns_enabled           = var.is_hns_enabled
  tags                     = var.tags

  network_rules {
    #default action is Allow dy default
    #if there is ip_rules or virtual_network_subnet_ids specified , defautl_action become to Deny = only added ip_rules or virtual_network_subnet_ids are permitted
    default_action             = (length(var.ip_rules) + length(var.virtual_network_subnet_ids)) > 0 ? "Deny" : var.default_action
    ip_rules                   = var.ip_rules
    virtual_network_subnet_ids = var.virtual_network_subnet_ids
  }
  
  #Azure will create and manage the identity of the resource (the Storage Account, in this case)
  identity {
    type = "SystemAssigned"
  }

  # if you change the tags in UI or CLI  , when you run terraform apply , terraform will not correct the conflics 
  # In another world, tags dont have to be managed by Terraform 
  lifecycle {
    ignore_changes = [
        tags
    ]
  }
}