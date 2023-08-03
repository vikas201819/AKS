# create 

az extension add --name alb

$AKS_NAME="aks-cluster"
$RG="rg-aks"
$LOCATION="westeurope"
$IDENTITY_ALB="identity-azure-alb"

az group create --name $RG --location $LOCATION -o table

az aks create `
    --resource-group $RG `
    --name $AKS_NAME `
    --location $LOCATION `
    --network-plugin azure `
    --enable-oidc-issuer `
    --enable-workload-identity `
    --output table

# Install the ALB Controller

# Creating identity $IDENTITY_ALB in resource group $RG

az identity create --resource-group $RG --name $IDENTITY_ALB --output table

$IDENTITY_ILB_PRINCIPAL_ID="$(az identity show -g $RG -n $IDENTITY_ALB --query principalId -otsv)"
echo $IDENTITY_ILB_PRINCIPAL_ID

# Waiting 60 seconds to allow for replication of the identity..."
sleep 60

# Apply Reader role to the AKS managed cluster resource group for the newly provisioned identity

$MC_RG=$(az aks show --name $AKS_NAME --resource-group $RG --query "nodeResourceGroup" -o tsv)
echo $MC_RG

$MC_RG_ID=$(az group show --name $MC_RG --query id -otsv)
echo $MC_RG_ID

# Reader role
az role assignment create --assignee-object-id $IDENTITY_ILB_PRINCIPAL_ID `
        --assignee-principal-type ServicePrincipal `
        --scope $MC_RG_ID --role "acdd72a7-3385-48ef-bd42-f606fba81ae7" `
        --output table 

# Set up federation with AKS OIDC issuer

$AKS_OIDC_ISSUER="$(az aks show -n $AKS_NAME -g $RG --query "oidcIssuerProfile.issuerUrl" -o tsv)"
echo $AKS_OIDC_ISSUER

az identity federated-credential create --name "identity-azure-alb" `
    --identity-name $IDENTITY_ALB `
    --resource-group $RG `
    --issuer $AKS_OIDC_ISSUER `
    --subject "system:serviceaccount:azure-alb-system:alb-controller-sa" `
    --output table

# ALB Controller can be installed by running the following commands

az aks get-credentials --resource-group $RG --name $AKS_NAME

$IDENTITY_ILB_CLIENT_ID=$(az identity show -g $RG -n $IDENTITY_ALB --query clientId -o tsv)

helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller `
     --version 0.4.023971 `
     --set albController.podIdentity.clientID=$IDENTITY_ILB_CLIENT_ID

# Verify the ALB Controller installation
kubectl get pods -n azure-alb-system
# NAME                                        READY   STATUS    RESTARTS   AGE
# alb-controller-764cf9ccdf-hf8v6             1/1     Running   0          59s
# alb-controller-bootstrap-5c6c59c7b8-cspg7   1/1     Running   0          60s

# Verify GatewayClass azure-application-lb is installed on your cluster
kubectl get gatewayclass azure-alb-external -o yaml
# apiVersion: gateway.networking.k8s.io/v1beta1
# kind: GatewayClass
# metadata:
#   creationTimestamp: "2023-08-02T12:05:35Z"
#   generation: 1
#   name: azure-alb-external
#   resourceVersion: "9475"
#   uid: 67b4f671-2cee-4e4b-942b-296964da9e97
# spec:
#   controllerName: alb.networking.azure.io/alb-controller
# status:
#   conditions:
#   - lastTransitionTime: "2023-08-02T12:05:57Z"
#     message: Valid GatewayClass
#     observedGeneration: 1
#     reason: Accepted
#     status: "True"
#     type: Accepted

# Create the Application Gateway for Containers resource
$AGFC_NAME='appgwc-alb' # Name of the Application Gateway for Containers resource to be created
az network alb create -g $RG -n $AGFC_NAME

# Create a frontend resource
$FRONTEND_NAME='frontend-app'
az network alb frontend create -g $RG -n $FRONTEND_NAME --alb-name $AGFC_NAME

$CLUSTER_SUBNET_ID=$(az vmss list --resource-group $MC_RG --query '[0].virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' -o tsv)
echo $CLUSTER_SUBNET_ID

$VNET_NAME=$(az network vnet show --ids $CLUSTER_SUBNET_ID --query name -o tsv)
echo $VNET_NAME

$VNET_RG=$(az network vnet show --ids $CLUSTER_SUBNET_ID --query resourceGroup -o tsv)
echo $VNET_RG

$VNET_ID=$(az network vnet show --ids $CLUSTER_SUBNET_ID --query id -o tsv)
echo $VNET_ID

# create a new subnet containing at least 250 available IP addresses 
# and enable subnet delegation for the Application Gateway for Containers association resource

$SUBNET_ADDRESS_PREFIX="10.225.0.0/24"
$ALB_SUBNET_NAME="subnet-alb" # subnet name can be any non-reserved subnet name (i.e. GatewaySubnet, AzureFirewallSubnet, AzureBastionSubnet would all be invalid)

az network vnet subnet create `
  --resource-group $VNET_RG `
  --vnet-name $VNET_NAME `
  --name $ALB_SUBNET_NAME `
  --address-prefixes $SUBNET_ADDRESS_PREFIX `
  --delegations "Microsoft.ServiceNetworking/trafficControllers" `
  --output table

$ALB_SUBNET_ID=$(az network vnet subnet show --name $ALB_SUBNET_NAME --resource-group $VNET_RG --vnet-name $VNET_NAME --query '[id]' --output tsv)
echo $ALB_SUBNET_ID

$IDENTITY_ILB_PRINCIPAL_ID=$(az identity show -g $RG -n $IDENTITY_ALB --query principalId -otsv)
echo $IDENTITY_ILB_PRINCIPAL_ID

$RG_ID=$(az group show --name $RG --query id -otsv)

# Delegate AppGw for Containers Configuration Manager role to AKS Managed Cluster RG
az role assignment create --assignee-object-id $IDENTITY_ILB_PRINCIPAL_ID `
        --assignee-principal-type ServicePrincipal `
        --scope $RG_ID `
        --role "fbc52c3f-28ad-4303-a892-8a056630b8f1" 

# Delegate Network Contributor permission for join to association subnet
az role assignment create --assignee-object-id $IDENTITY_ILB_PRINCIPAL_ID `
        --assignee-principal-type ServicePrincipal `
        --scope $ALB_SUBNET_ID `
        --role "4d97b98b-1d4f-4787-a291-c67834d212e7"

# Create an association resource

# Execute the following command to create the association resource and connect it to the referenced subnet. 
# It can take 5-6 minutes for the Application Gateway for Containers association to be created.

$AGFC_ASSOCIATION="association-app"
az network alb association create -g $RG -n $AGFC_ASSOCIATION --alb-name $AGFC_NAME --subnet $ALB_SUBNET_ID

# Create Gateway resource

$AGFC_ID=$(az network alb show --resource-group $RG --name $AGFC_NAME --query id -o tsv)
echo $AGFC_ID

@"
apiVersion: v1
kind: Namespace
metadata:
  name: ns-gateway
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: gateway-app
  namespace: ns-gateway
  annotations:
    alb.networking.azure.io/alb-id: $AGFC_ID
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: http-listener
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
  addresses:
  - type: alb.networking.azure.io/alb-frontend
    value: $FRONTEND_NAME
"@ > gateway.byo.yaml

kubectl apply -f gateway.byo.yaml

# Once the gateway resource has been created, ensure the status is valid, the listener is Programmed, and an address is assigned to the gateway.
kubectl get gateway gateway-app -n ns-gateway -o yaml
# apiVersion: gateway.networking.k8s.io/v1beta1
# kind: Gateway
# metadata:
#   annotations:
#     alb.networking.azure.io/alb-name: alb-appgwc
#     alb.networking.azure.io/alb-namespace: alb-infra
#     kubectl.kubernetes.io/last-applied-configuration: |
#       {"apiVersion":"gateway.networking.k8s.io/v1beta1","kind":"Gateway","metadata":{"annotations":{"alb.networking.azure.io/alb-name":"alb-appgwc","alb.networking.azure.io/alb-namespace":"alb-infra"},"name":"gateway-app","namespace":"ns-gateway"},"spec":{"gatewayClassName":"azure-alb-external","listeners":[{"allowedRoutes":{"namespaces":{"from":"All"}},"name":"http-listener","port":80,"protocol":"HTTP"}]}}
#   creationTimestamp: "2023-08-03T19:30:08Z"
#   generation: 1
#   name: gateway-app
#   namespace: ns-gateway
#   resourceVersion: "439944"
#   uid: e15df409-5173-454c-a361-4e694eb832b6
# spec:
#   gatewayClassName: azure-alb-external
#   listeners:
#   - allowedRoutes:
#       namespaces:
#         from: All
#     name: http-listener
#     port: 80
#     protocol: HTTP
# status:
#   addresses:
#   - type: IPAddress
#     value: 883b5b332d03c5cc305d1202de2cb5bb.fz15.alb.azure.com
#   conditions:
#   - lastTransitionTime: "2023-08-03T19:31:34Z"
#     message: Valid Gateway
#     observedGeneration: 1
#     reason: Accepted
#     status: "True"
#     type: Accepted
#   - lastTransitionTime: "2023-08-03T19:31:35Z"
#     message: Application Gateway for Containers resource has been successfully updated.
#     observedGeneration: 1
#     reason: Programmed
#     status: "True"
#     type: Programmed
#   listeners:
#   - attachedRoutes: 1
#     conditions:
#     - lastTransitionTime: "2023-08-03T19:31:34Z"
#       message: ""
#       observedGeneration: 1
#       reason: ResolvedRefs
#       status: "True"
#       type: ResolvedRefs
#     - lastTransitionTime: "2023-08-03T19:31:34Z"
#       message: Listener is Accepted
#       observedGeneration: 1
#       reason: Accepted
#       status: "True"
#       type: Accepted
#     - lastTransitionTime: "2023-08-03T19:31:35Z"
#       message: Application Gateway for Containers resource has been successfully updated.
#       observedGeneration: 1
#       reason: Programmed
#       status: "True"
#       type: Programmed
#     name: http-listener
#     supportedKinds:
#     - group: gateway.networking.k8s.io
#       kind: HTTPRoute

kubectl get gateway gateway-app -n ns-gateway -o jsonpath='{.status.addresses[0].value}'
# 883b5b332d03c5cc305d1202de2cb5bb.fz15.alb.azure.com

# deploy sample app
kubectl apply -f ns-deploy-svc.yaml
# namespace/ns-app created
# service/svc-app created
# deployment.apps/deploy-app created

kubectl apply -f httproute.yaml
# httproute.gateway.networking.k8s.io/httproute-app created

kubectl get httproute -A
# NAMESPACE   NAME            HOSTNAMES   AGE
# ns-app      httproute-app               2m34s