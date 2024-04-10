
 resource "local_file" "kubeconfig" {
   depends_on = [azurerm_kubernetes_cluster.aks]
   filename   = "kubeconfig"
   content    = azurerm_kubernetes_cluster.aks.kube_config_raw
 }

 output "appgw_pip_address" {
   value = azurerm_public_ip.appgw.ip_address
 }


 output "appgw_id" {
   value = azurerm_application_gateway.network.id
 }