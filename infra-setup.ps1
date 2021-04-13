$RG="ADC-demo"
$ACR="lncadcacr"
$VNET="adcvnet"
$AKSSUBNET="akssubnet"
#$AKSPOOLSUBNET="akspool"
$AKS="adcaks"

az group create --name $RG --location EastUS2

az network vnet create -g $RG -n $VNET --address-prefix 10.0.0.0/16 `
    --subnet-name sub1 --subnet-prefix 10.0.0.0/24
az network vnet subnet create --name $AKSSUBNET --vnet-name $VNET -g $RG --address-prefixes 10.0.128.0/17

# Create ACR; build and upload docker image
az acr create -n $ACR -g $RG -l EastUS2 --sku Standard
az acr build -r $ACR -t lncvote azure-vote --no-wait

# Create azure cni cluster using user-managed identity; no acr integration
$AKSSUBNETID=$(az network vnet subnet list -g $RG --vnet-name $VNET --query "[?name=='$AKSSUBNET'].id" --output tsv)
$ident=$(az identity create --name lncadcIdentity --resource-group $RG -o json)
$clientid=$($ident|convertfrom-json).id

az aks create -g $RG -n $AKS -l EastUS2  --network-plugin azure `
-c 3 -z 1 2 3 `
--enable-managed-identity `
--assign-identity $clientid `
--vnet-subnet-id  $AKSSUBNETID  `
--service-cidr   172.17.0.0/16 `
--dns-service-ip   172.17.0.10   `
--docker-bridge-address  192.168.0.1/16 
az aks get-credentials -g $RG -n $AKS


#az aks check-acr -g $RG -n $AKS --acr "$ACR.azurecr.io"
az aks update -g $RG -n $AKS --attach-acr $ACR 
az aks check-acr -g $RG -n $AKS --acr "$ACR.azurecr.io"

############ Ingress
# Create a namespace for your ingress resources
$NS="ingress-demo"
kubectl create namespace $NS

# Add the ingress-nginx repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

# Use Helm to deploy an NGINX ingress controller
helm install nginx-ingress ingress-nginx/ingress-nginx `
    --namespace $NS `
    --set controller.replicaCount=2 `
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux `
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux `
    --set controller.admissionWebhooks.patch.nodeSelector."beta\.kubernetes\.io/os"=linux

kubectl apply -f .\ingress.yml --namespace $NS
###########################
# DNS Demo
# DNS looks up <namespace>.svc.cluster.local svc.cluster.local cluster.local
kubectl run -i -t --image=busybox /bin/bash

#########
# Taint & Tolerances
az aks nodepool list -g $RG --cluster-name $AKS
az aks nodepool add -g $RG --cluster-name $AKS `
    --name gpupool --node-count 1 `
    --node-taints sku=gpu:NoSchedule `
    --labels sku=gpu `
    --no-wait

# kubectl taint nodes node1 key1=value1:NoSchedule
kubectl apply -f .\taintdemo.yml

################################ 
# AAD Integration

$user=$(az ad signed-in-user show -o json|convertfrom-json)
az aks update -g $RG -n $AKS --enable-aad --aad-admin-group-object-ids $user.objectId
$spdemo=$(az ad sp create-for-rbac -n lncaks --skip-assignment -o json|convert)
$objid=$(az ad sp show --id $spdemo.id --query "objectId" -o json)
echo "Object ID for rolebinding is $objid"

$AKSID=$(az aks show -n $AKS -g $RG -o json|convertfrom-json).id 
az role assignment create --assignee $spdemo.name  --role "Azure Kubernetes Service Cluster User Role" --scope $AKSID

kubectl create namespace dev
kubectl apply -f .\dev-role-rolebinding.yaml
#### next, in the other session:
az login --service-principal -u http://lncaks -p <pwd> --tenant 72f988bf-86f1-41af-91ab-2d7cd011db47
az aks get-credentials -n adcaks -g  ADC-demo1
kubelogin convert-kubeconfig -l spn
export AAD_SERVICE_PRINCIPAL_CLIENT_ID=<spn client id>
export AAD_SERVICE_PRINCIPAL_CLIENT_SECRET=<spn secret>









exit
###############################
# Create Kubenet Cluster
# Create kubnet cluster using user-managed identity; no acr integration
$SUBNETID=$(az network vnet subnet list -g $RG --vnet-name $VNET --query "[?name=='$AKSSUBNET'].id" --output tsv); $SUBNETID
$ident=$(az identity create --name lncadcIdentity --resource-group $RG -o json)
$clientid=$($ident|convertfrom-json).id
$AKS="adcaks-kn"
az aks create -g $RG -n $AKS -l EastUS2  --network-plugin kubenet `
-c 3 -z 1 2 3 `
--vnet-subnet-id  $SUBNETID  `
--enable-managed-identity `
--assign-identity $clientid `
--pod-cidr   172.16.0.0/16 `
--service-cidr   172.17.0.0/16 `
--dns-service-ip   172.17.0.10   `
--docker-bridge-address  192.168.0.1/16 