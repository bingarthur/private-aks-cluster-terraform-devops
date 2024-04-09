terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.50"
    }
  }
}

provider "azurerm" {
  features {}
}

terraform {
  backend "azurerm" {
  }
}

locals {
  storage_account_prefix = "boot"
  route_table_name       = "DefaultRouteTable"
  route_name             = "RouteToAzureFirewall"
}

data "azurerm_client_config" "current" {
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

#Enable container insight for AKS
#Can be seen as Splunk
module "log_analytics_workspace" {
  source                           = "./modules/log_analytics"
  name                             = var.log_analytics_workspace_name
  location                         = var.location
  resource_group_name              = azurerm_resource_group.rg.name
  solution_plan_map                = var.solution_plan_map
}

/*
创建Hub Vnet，并创建2个subnet给firewall and basetion service
*/
module "hub_network" {
  source                       = "./modules/virtual_network"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.location
  vnet_name                    = var.hub_vnet_name
  address_space                = var.hub_address_space
  tags                         = var.tags
  # enable log analytics, 具体哪些logs 哪些metrics见virtual_network module
  log_analytics_workspace_id   = module.log_analytics_workspace.id

  subnets = [
    {
      name : "AzureFirewallSubnet"
      address_prefixes : var.hub_firewall_subnet_address_prefix
      private_endpoint_network_policies_enabled : true 
      private_link_service_network_policies_enabled : false
    },
    {
      name : "AzureBastionSubnet"
      address_prefixes : var.hub_bastion_subnet_address_prefix
      #private endpoint is the service consumer,like Bastion VM
      # we need to enable private endpoint in Bastion , so its true here 
      private_endpoint_network_policies_enabled : true
      #private link service is the service provider , like ACR
      # we dont need to enable private link service here, so its false here 
      private_link_service_network_policies_enabled : false
    }
  ]
}

/*
创建Spoke Vnet，并创建4个subnet
default node pool, additonal node pool,pod subnet,bastion VM 
*/
module "aks_network" {
  source                       = "./modules/virtual_network"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.location
  vnet_name                    = var.aks_vnet_name
  address_space                = var.aks_vnet_address_space #["10.0.0.0/16"]
  log_analytics_workspace_id   = module.log_analytics_workspace.id

  subnets = [
    {
      name : var.default_node_pool_subnet_name
      address_prefixes : var.default_node_pool_subnet_address_prefix #["10.0.0.0/20"]
      private_endpoint_network_policies_enabled : true
      private_link_service_network_policies_enabled : false
    },
    {
      name : var.additional_node_pool_subnet_name
      address_prefixes : var.additional_node_pool_subnet_address_prefix #["10.0.16.0/20"]
      private_endpoint_network_policies_enabled : true
      private_link_service_network_policies_enabled : false
    },
    {
      name : var.pod_subnet_name
      address_prefixes : var.pod_subnet_address_prefix #["10.0.32.0/20"]
      private_endpoint_network_policies_enabled : true
      private_link_service_network_policies_enabled : false
    },
    {
      name : var.vm_subnet_name
      address_prefixes : var.vm_subnet_address_prefix #["10.0.48.0/20"]
      private_endpoint_network_policies_enabled : true
      private_link_service_network_policies_enabled : false
    }
  ]
}

#connect Hub Vnet with Spoke Vnet
module "vnet_peering" {
  source              = "./modules/virtual_network_peering"
  vnet_1_name         = var.hub_vnet_name
  vnet_1_id           = module.hub_network.vnet_id
  vnet_1_rg           = azurerm_resource_group.rg.name
  vnet_2_name         = var.aks_vnet_name
  vnet_2_id           = module.aks_network.vnet_id
  vnet_2_rg           = azurerm_resource_group.rg.name
  peering_name_1_to_2 = "${var.hub_vnet_name}To${var.aks_vnet_name}"
  peering_name_2_to_1 = "${var.aks_vnet_name}To${var.hub_vnet_name}"
}

/*
firewall module中默认创建了network rules和application rules
具体注释见module文件
module里面并没有创建NAT rule，如果firewall后面的是一个VM要暴露22端口的话，使用NAT比较好，因为firewall是layer4 
但是AKS的话，要暴露的是application，最好使用layer7 LB，比如AGIC+WAF
如果非要使用firewall+ingress的形式，见架构图firewall-internal-load-balacer.png，创建NAT rule来暴露internal ingress（nginx）
*/

module "firewall" {
  source                       = "./modules/firewall"
  name                         = var.firewall_name
  resource_group_name          = azurerm_resource_group.rg.name
  zones                        = var.firewall_zones
  #Azure Firewall's Threat Intelligence-based filtering
  #Off,Alers:send alert,dont block traffic,Deny:block traffic 
  threat_intel_mode            = var.firewall_threat_intel_mode
  location                     = var.location
  #AZFW_Hub or AZFW_VNet
  #AZFW_Hub: This SKU is used when you want to associate Azure Firewall with a Virtual Hub (vhub).It is used in the context of Azure Virtual WAN, a networking service that provides optimized and automated branch-to-branch connectivity.
  #AZFW_VNet: This SKU is used for a standard deployment of Azure Firewall, where the firewall is associated with a specific Virtual Network (vNet). It's the default option and is typically intended for more basic firewall setups.
  sku_name                     = var.firewall_sku_name 
  #Standard or Premium
  sku_tier                     = var.firewall_sku_tier
  pip_name                     = "${var.firewall_name}PublicIp"
  subnet_id                    = module.hub_network.subnet_ids["AzureFirewallSubnet"]
  log_analytics_workspace_id   = module.log_analytics_workspace.id
}

/*
在所有的node pool subnet中添加一个route table
并添加一条route，这条route定义所有的outbound（0.0.0.0），都转发给firewall的private IP
*/
module "routetable" {
  source               = "./modules/route_table"
  resource_group_name  = azurerm_resource_group.rg.name
  location             = var.location
  route_table_name     = local.route_table_name
  route_name           = local.route_name
  firewall_private_ip  = module.firewall.private_ip_address
  subnets_to_associate = {
    (var.default_node_pool_subnet_name) = {
      subscription_id      = data.azurerm_client_config.current.subscription_id
      resource_group_name  = azurerm_resource_group.rg.name
      virtual_network_name = module.aks_network.name
    }
    (var.additional_node_pool_subnet_name) = {
      subscription_id      = data.azurerm_client_config.current.subscription_id
      resource_group_name  = azurerm_resource_group.rg.name
      virtual_network_name = module.aks_network.name
    }
  }
}

/*
创建一个ACR
*/
module "container_registry" {
  source                       = "./modules/container_registry"
  name                         = var.acr_name
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.location
  sku                          = var.acr_sku #["Basic", "Standard", "Premium"]
  admin_enabled                = var.acr_admin_enabled # true
  georeplication_locations     = var.acr_georeplication_locations #Dont need geo replica by default
  # enable log analytics, 具体哪些logs 哪些metrics见container_registry module
  log_analytics_workspace_id   = module.log_analytics_workspace.id
}

module "aks_cluster" {
  source                                   = "./modules/aks"
  name                                     = var.aks_cluster_name
  location                                 = var.location
  resource_group_name                      = azurerm_resource_group.rg.name
  resource_group_id                        = azurerm_resource_group.rg.id
  kubernetes_version                       = var.kubernetes_version
  dns_prefix                               = lower(var.aks_cluster_name)
  private_cluster_enabled                  = true
  automatic_channel_upgrade                = var.automatic_channel_upgrade
  sku_tier                                 = var.sku_tier
  default_node_pool_name                   = var.default_node_pool_name
  default_node_pool_vm_size                = var.default_node_pool_vm_size
  vnet_subnet_id                           = module.aks_network.subnet_ids[var.default_node_pool_subnet_name]
  default_node_pool_availability_zones     = var.default_node_pool_availability_zones
  default_node_pool_node_labels            = var.default_node_pool_node_labels
  default_node_pool_node_taints            = var.default_node_pool_node_taints
  default_node_pool_enable_auto_scaling    = var.default_node_pool_enable_auto_scaling
  default_node_pool_enable_host_encryption = var.default_node_pool_enable_host_encryption
  default_node_pool_enable_node_public_ip  = var.default_node_pool_enable_node_public_ip
  default_node_pool_max_pods               = var.default_node_pool_max_pods
  default_node_pool_max_count              = var.default_node_pool_max_count
  default_node_pool_min_count              = var.default_node_pool_min_count
  default_node_pool_node_count             = var.default_node_pool_node_count
  default_node_pool_os_disk_type           = var.default_node_pool_os_disk_type
  tags                                     = var.tags
  network_dns_service_ip                   = var.network_dns_service_ip
  network_plugin                           = var.network_plugin
  outbound_type                            = "userDefinedRouting"
  network_service_cidr                     = var.network_service_cidr
  log_analytics_workspace_id               = module.log_analytics_workspace.id
  role_based_access_control_enabled        = var.role_based_access_control_enabled
  tenant_id                                = data.azurerm_client_config.current.tenant_id
  admin_group_object_ids                   = var.admin_group_object_ids
  azure_rbac_enabled                       = var.azure_rbac_enabled
  admin_username                           = var.admin_username
  ssh_public_key                           = var.ssh_public_key
  keda_enabled                             = var.keda_enabled
  vertical_pod_autoscaler_enabled          = var.vertical_pod_autoscaler_enabled
  workload_identity_enabled                = var.workload_identity_enabled
  oidc_issuer_enabled                      = var.oidc_issuer_enabled
  open_service_mesh_enabled                = var.open_service_mesh_enabled
  image_cleaner_enabled                    = var.image_cleaner_enabled
  azure_policy_enabled                     = var.azure_policy_enabled
  http_application_routing_enabled         = var.http_application_routing_enabled

  depends_on                               = [module.routetable]
}

resource "azurerm_role_assignment" "network_contributor" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Network Contributor"
  principal_id         = module.aks_cluster.aks_identity_principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "acr_pull" {
  role_definition_name = "AcrPull"
  scope                = module.container_registry.id
  principal_id         = module.aks_cluster.kubelet_identity_object_id
  skip_service_principal_aad_check = true
}

# Generate randon name for virtual machine
resource "random_string" "storage_account_suffix" {
  length  = 8
  special = false
  lower   = true
  upper   = false
  numeric  = false
}

/*
module中也有注释
ip_rules 是module中的变量，你要使用module就要给module中的变量赋值
storage_account_ip_rules  是主程序的变量，通过这个变量给module中的变量赋值
主程序中的变量
这个storage account是用来存储VM boot logs
*/
module "storage_account" {
  source                      = "./modules/storage_account"
  name                        = "${local.storage_account_prefix}${random_string.storage_account_suffix.result}"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.rg.name
  account_kind                = var.storage_account_kind #StorageV2
  account_tier                = var.storage_account_tier #["Standard", "Premium"]
  replication_type            = var.storage_account_replication_type #LRS
  #whether the hierarchical namespace (HNS) is enabled for that account.
  #a hierarchical namespace enables Azure Data Lake Storage Gen2 features and is required to create a Data Lake Storage Gen2 account
  #Once you enable the HNS on a storage account, it can't be disabled.
  is_hns_enabled              = var.storage_account_is_hns_enabled # default false
  #默认的storage account是允许所有访问，如果要设置访问列表的话，uncomment below code
  #ip_rules                   = var.storage_account_ip_rules
  #virtual_network_subnet_ids = module.virtual_machine.subnet_id #只允许VM访问这个storage account
}

/*
创建一个Basetion host （network service which is used to connect to VM from Azure portal）
*/
module "bastion_host" {
  source                       = "./modules/bastion_host"
  name                         = var.bastion_host_name
  location                     = var.location
  resource_group_name          = azurerm_resource_group.rg.name
  /*
  this is the output which is defind in virtual_network modulefor "subnet in azurerm_subnet.subnet : subnet.name => subnet.id"
  return value like below 
  {
  "AzureBastionSubnet" = "subnet-0a2846f2j276hsds"
  "AzureFirewallSubnet" = "subnet-0d2768r2j431pqrs"
  }
  *****引用方法module.<module_name>.<module_output_var>
  */
  subnet_id                    = module.hub_network.subnet_ids["AzureBastionSubnet"]
  log_analytics_workspace_id   = module.log_analytics_workspace.id
}

/*
创建一个Basetion VM
*/
module "virtual_machine" {
  source                              = "./modules/virtual_machine"
  name                                = var.vm_name
  size                                = var.vm_size #Standard_DS1_v2
  location                            = var.location
  #false，dont create PIP for this VM
  #true, create 1 PIP for this VM , the logic is define in module
  public_ip                           = var.vm_public_ip 
  vm_user                             = var.admin_username #azadmin
  admin_ssh_public_key                = var.ssh_public_key # key pair name which is uploaded to EC2 service
  os_disk_image                       = var.vm_os_disk_image #见module注释
  #if you add PIP to this VM , it will bind to a FQDN, like <domain_name>.<region>.cloudapp.azure.com
  domain_name_label                   = var.domain_name_label
  resource_group_name                 = azurerm_resource_group.rg.name
  subnet_id                           = module.aks_network.subnet_ids[var.vm_subnet_name]
  os_disk_storage_account_type        = var.vm_os_disk_storage_account_type #StandardSSD_LRS
  boot_diagnostics_storage_account    = module.storage_account.primary_blob_endpoint #见module注释
  ##enable monitor agent and Dependency agent in VM and send metrics to this log analytics 
  # see comments in module
  log_analytics_workspace_id          = module.log_analytics_workspace.workspace_id
  log_analytics_workspace_key         = module.log_analytics_workspace.primary_shared_key
  log_analytics_workspace_resource_id = module.log_analytics_workspace.id

  # 如果需要enable custom_script 见module注释 ，则在执行的时候，需要在tfvars中指定这4个变量,用来指定custom script的存储位置
  # 这4个变量的default value是null，不指定的话， 这些settings就会被terraform omitted
  script_storage_account_name         = var.script_storage_account_name
  script_storage_account_key          = var.script_storage_account_key
  container_name                      = var.container_name
  script_name                         = var.script_name
}

module "node_pool" {
  source = "./modules/node_pool"
  resource_group_name = azurerm_resource_group.rg.name
  kubernetes_cluster_id = module.aks_cluster.id
  name                         = var.additional_node_pool_name
  vm_size                      = var.additional_node_pool_vm_size
  mode                         = var.additional_node_pool_mode
  node_labels                  = var.additional_node_pool_node_labels
  node_taints                  = var.additional_node_pool_node_taints
  availability_zones           = var.additional_node_pool_availability_zones
  vnet_subnet_id               = module.aks_network.subnet_ids[var.additional_node_pool_subnet_name]
  enable_auto_scaling          = var.additional_node_pool_enable_auto_scaling
  enable_host_encryption       = var.additional_node_pool_enable_host_encryption
  enable_node_public_ip        = var.additional_node_pool_enable_node_public_ip
  orchestrator_version         = var.kubernetes_version
  max_pods                     = var.additional_node_pool_max_pods
  max_count                    = var.additional_node_pool_max_count
  min_count                    = var.additional_node_pool_min_count
  node_count                   = var.additional_node_pool_node_count
  os_type                      = var.additional_node_pool_os_type
  priority                     = var.additional_node_pool_priority
  tags                         = var.tags

  depends_on                   = [module.routetable]
}

/*

*/
module "key_vault" {
  source                          = "./modules/key_vault"
  name                            = var.key_vault_name
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg.name
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  sku_name                        = var.key_vault_sku_name #standard
  tags                            = var.tags
  enabled_for_deployment          = var.key_vault_enabled_for_deployment
  enabled_for_disk_encryption     = var.key_vault_enabled_for_disk_encryption
  enabled_for_template_deployment = var.key_vault_enabled_for_template_deployment
  enable_rbac_authorization       = var.key_vault_enable_rbac_authorization
  purge_protection_enabled        = var.key_vault_purge_protection_enabled
  soft_delete_retention_days      = var.key_vault_soft_delete_retention_days
  bypass                          = var.key_vault_bypass
  default_action                  = var.key_vault_default_action
  log_analytics_workspace_id      = module.log_analytics_workspace.id
}

/*
subnet_id是Bastion VM的subnet，在这个subnet中创建一个endpoint，这个endpoint是连接到acr的。private_connection_resource_id中确定是连接到acr的
Bastion VM通过这个endpint就可以访问到ACR了
*/
module "acr_private_endpoint" {
  source                         = "./modules/private_endpoint"
  name                           = "${module.container_registry.name}PrivateEndpoint"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.rg.name
  subnet_id                      = module.aks_network.subnet_ids[var.vm_subnet_name]
  tags                           = var.tags
  private_connection_resource_id = module.container_registry.id
  is_manual_connection           = false
  subresource_name               = "registry"
  private_dns_zone_group_name    = "AcrPrivateDnsZoneGroup"
  private_dns_zone_group_ids     = [module.acr_private_dns_zone.id]
}

/*
通过private endpoint（如上），bastion可以访问ACR，但是如果要通过FQDN访问acr的话，就需要给ACR一个DNS
virtual_networks_to_link：Link VNET到这个private DNS，然后linked Vnet中的资源就可以访问ACR的private FQDN
*/
module "acr_private_dns_zone" {
  source                       = "./modules/private_dns_zone"
  name                         = "privatelink.azurecr.io"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_networks_to_link     = {
    (module.hub_network.name) = {
      subscription_id = data.azurerm_client_config.current.subscription_id
      resource_group_name = azurerm_resource_group.rg.name
    }
    (module.aks_network.name) = {
      subscription_id = data.azurerm_client_config.current.subscription_id
      resource_group_name = azurerm_resource_group.rg.name
    }
  }
}

module "key_vault_private_dns_zone" {
  source                       = "./modules/private_dns_zone"
  name                         = "privatelink.vaultcore.azure.net"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_networks_to_link     = {
    (module.hub_network.name) = {
      subscription_id = data.azurerm_client_config.current.subscription_id
      resource_group_name = azurerm_resource_group.rg.name
    }
    (module.aks_network.name) = {
      subscription_id = data.azurerm_client_config.current.subscription_id
      resource_group_name = azurerm_resource_group.rg.name
    }
  }
}

module "blob_private_dns_zone" {
  source                       = "./modules/private_dns_zone"
  name                         = "privatelink.blob.core.windows.net"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_networks_to_link     = {
    (module.hub_network.name) = {
      subscription_id = data.azurerm_client_config.current.subscription_id
      resource_group_name = azurerm_resource_group.rg.name
    }
    (module.aks_network.name) = {
      subscription_id = data.azurerm_client_config.current.subscription_id
      resource_group_name = azurerm_resource_group.rg.name
    }
  }
}



module "key_vault_private_endpoint" {
  source                         = "./modules/private_endpoint"
  name                           = "${title(module.key_vault.name)}PrivateEndpoint"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.rg.name
  subnet_id                      = module.aks_network.subnet_ids[var.vm_subnet_name]
  tags                           = var.tags
  private_connection_resource_id = module.key_vault.id
  is_manual_connection           = false
  subresource_name               = "vault"
  private_dns_zone_group_name    = "KeyVaultPrivateDnsZoneGroup"
  private_dns_zone_group_ids     = [module.key_vault_private_dns_zone.id]
}

module "blob_private_endpoint" {
  source                         = "./modules/private_endpoint"
  name                           = "${title(module.storage_account.name)}PrivateEndpoint"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.rg.name
  subnet_id                      = module.aks_network.subnet_ids[var.vm_subnet_name]
  tags                           = var.tags
  private_connection_resource_id = module.storage_account.id
  is_manual_connection           = false
  subresource_name               = "blob"
  private_dns_zone_group_name    = "BlobPrivateDnsZoneGroup"
  private_dns_zone_group_ids     = [module.blob_private_dns_zone.id]
}
