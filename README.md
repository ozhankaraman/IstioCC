# Istio 19 Cross Cluster and Cluster DNS Setup
After Istio 1.7 cross cluster design by defining service entries became depreciated and they moved to a new Cross Cluster approach with Multi Primary, Multi Primary Remote Cluster Design. https://istio.io/latest/docs/setup/install/multicluster/ . There are also some articles and support tickets on Istio site that after Istio 1.6 old Cluster Service Entry CC Design did not work as expected and its like broken for a while ( https://github.com/istio/istio/issues/29308#issuecomment-736899243 ).

You could get different cluster approaches from Istio documentation but here i plan to give some example scenarios about Istio Cross Cluster Usage. Here i am using 3 clusters named C1, C2 and C3. They have different region and zone setup. We could use any cluster installed on any cloud provider or onpremise platform. Important thing here is update the region and zone details with your current design and Load Balancer VIPS needs to be accessed by 3 clusters.

Here i am using 3 clusters installed with Kubeadm project, they each have 3 or 5 worker nodes. I am using a Multi Primary Cluster Architecture over different networks under same mesh topology. So generally all pods, services are isolated from each other, they could not directly communicate with each other. You could think these 3 clusters as clusters like in London, New York, Tokyo cities. You could get more data over the https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network link which give more details about how data flows from one clusters service to other clusters service.

I used Istio Operator to manage Istio installation because it looks like its more native, its used by most of the contributors and has strong abilities on Cluster Upgrade and Troubleshooting. 

Its also important that each cluster is using same CA that allows to use same root CA and then they could talk to each other without need to define any federation on each cluster mesh. By using same CA, clusters trust each other. https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/

I also enabled Istio Smart DNS Proxy to test how it works on cross cluster setup. It has a seamless integration with across multiple cluster and Virtual machines. 

I generally used the cross cluster examples which comes with Istio bundle, generally nothing special here, only the official documentation is somekind of complex to understand for a newcomer.

Cross Cluster Nodes are using the below zone and region distribution. Each Regions have different zones so zone1 from region1 is not zone as zone1 from region2

Cluster | Node | Region | Zone
-- | --| -- | --
C1 | c1n1 | region1 | zone1
C1 | c1n2 | region1 | zone2
C1 | c1n3 | region1 | zone2
-- | -- | -- | -- 
C2 | c2n1 | region2 | zone1
C2 | c2n2 | region2 | zone2
C2 | c2n3 | region2 | zone3
C2 | c2n4 | region4 | zone4
C2 | c2n5 | region4 | zone5
-- | --| -- | --
C3 | c3n1 | region3 | zone1
C3 | c3n2 | region3 | zone2
C3 | c3n3 | region3 | zone2

We use c1-admin, c2-admin, c3-admin kubectl contexts to reach clusters via kubectl or istioctl

# We follow the below steps to build up a 3 node CC Cluster
1. Deploy simple Kubernetes 1.20.4 cluster with Load Balancer Setup. I used MetalLB because my cluster is working over Linux KVM VM's and generally each node is a seperate vm. 
1. Label Nodes with Specific Region and Zone 
1. Generate Common CA for all clusters and generate tls secret
1. Deploy Istio Operator
1. Deploy Istiod
1. Deploy East-West Ingress GW to handle CC Communication
1. Expose Services on Clusters for Endpoint Discovery
1. Deploy Remote Secret for Endpoint Discovery on Clusters

## Label Nodes with Specific Region and Zone 
``` bash
kubectl --context=c1-admin label nodes c1n1 --overwrite topology.kubernetes.io/region=region1
kubectl --context=c1-admin label nodes c1n1 --overwrite topology.kubernetes.io/zone=zone1
kubectl --context=c1-admin label nodes c1n2 --overwrite topology.kubernetes.io/region=region1
kubectl --context=c1-admin label nodes c1n2 --overwrite topology.kubernetes.io/zone=zone2
kubectl --context=c1-admin label nodes c1n3 --overwrite topology.kubernetes.io/region=region1
kubectl --context=c1-admin label nodes c1n3 --overwrite topology.kubernetes.io/zone=zone3

kubectl --context=c2-admin label nodes c2n1 --overwrite topology.kubernetes.io/region=region2
kubectl --context=c2-admin label nodes c2n1 --overwrite topology.kubernetes.io/zone=zone1
kubectl --context=c2-admin label nodes c2n2 --overwrite topology.kubernetes.io/region=region2
kubectl --context=c2-admin label nodes c2n2 --overwrite topology.kubernetes.io/zone=zone2
kubectl --context=c2-admin label nodes c2n3 --overwrite topology.kubernetes.io/region=region2
kubectl --context=c2-admin label nodes c2n3 --overwrite topology.kubernetes.io/zone=zone3
kubectl --context=c2-admin label nodes c2n4 --overwrite topology.kubernetes.io/region=region4
kubectl --context=c2-admin label nodes c2n4 --overwrite topology.kubernetes.io/zone=zone4
kubectl --context=c2-admin label nodes c2n5 --overwrite topology.kubernetes.io/region=region4
kubectl --context=c2-admin label nodes c2n5 --overwrite topology.kubernetes.io/zone=zone5

kubectl --context=c3-admin label nodes c3n1 --overwrite topology.kubernetes.io/region=region3
kubectl --context=c3-admin label nodes c3n1 --overwrite topology.kubernetes.io/zone=zone1
kubectl --context=c3-admin label nodes c3n2 --overwrite topology.kubernetes.io/region=region3
kubectl --context=c3-admin label nodes c3n2 --overwrite topology.kubernetes.io/zone=zone2
kubectl --context=c3-admin label nodes c3n3 --overwrite topology.kubernetes.io/region=region3
kubectl --context=c3-admin label nodes c3n3 --overwrite topology.kubernetes.io/zone=zone3
```

## Generate Common CA for all clusters and generate tls secret
``` bash
# Below command is for macosx https://github.com/istio/istio/releases/tag/1.9.0
wget https://github.com/istio/istio/releases/download/1.9.0/istio-1.9.0-osx.tar.gz && \
  tar zxf istio-1.9.0-osx.tar.gz && rm -rf istio-1.9.0-osx.tar.gz
mkdir istio-certs
mkdir istio-certs/c1 istio-certs/c2 istio-certs/c3

cd istio-certs

make -f ../istio-1.9.0/tools/certs/Makefile.selfsigned.mk root-ca
make -f ../istio-1.9.0/tools/certs/Makefile.selfsigned.mk c1-cacerts
make -f ../istio-1.9.0/tools/certs/Makefile.selfsigned.mk c2-cacerts
make -f ../istio-1.9.0/tools/certs/Makefile.selfsigned.mk c3-cacerts

cd ..

# Generate tls secret for each cluster
# c1
kubectl --context=c1-admin create namespace istio-system
kubectl --context=c1-admin create secret generic cacerts -n istio-system \
      --from-file=istio-certs/c1/ca-cert.pem \
      --from-file=istio-certs/c1/ca-key.pem \
      --from-file=istio-certs/c1/root-cert.pem \
      --from-file=istio-certs/c1/cert-chain.pem


# c2
kubectl --context=c2-admin create namespace istio-system
kubectl --context=c2-admin create secret generic cacerts -n istio-system \
      --from-file=istio-certs/c2/ca-cert.pem \
      --from-file=istio-certs/c2/ca-key.pem \
      --from-file=istio-certs/c2/root-cert.pem \
      --from-file=istio-certs/c2/cert-chain.pem


# c3
kubectl --context=c3-admin create namespace istio-system
kubectl --context=c3-admin create secret generic cacerts -n istio-system \
      --from-file=istio-certs/c3/ca-cert.pem \
      --from-file=istio-certs/c3/ca-key.pem \
      --from-file=istio-certs/c3/root-cert.pem \
      --from-file=istio-certs/c3/cert-chain.pem
```

## Deploy Istio Operator
``` bash
./istio-1.9.0/bin/istioctl --context=c1-admin --hub=gcr.io/istio-release --tag=1.9.0 operator init
./istio-1.9.0/bin/istioctl --context=c2-admin --hub=gcr.io/istio-release --tag=1.9.0 operator init
./istio-1.9.0/bin/istioctl --context=c3-admin --hub=gcr.io/istio-release --tag=1.9.0 operator init
```

## Deploy Istiod
``` bash
# c1
cat << EOF | kubectl --context c1-admin apply -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiocontrolplane-default
  namespace: istio-system
spec:
  hub: gcr.io/istio-release
  tag: 1.9.0
  # revision: 1-9-0-1
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1

  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
EOF

# c2
cat << EOF | kubectl --context c2-admin apply -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiocontrolplane-default
  namespace: istio-system
spec:
  hub: gcr.io/istio-release
  tag: 1.9.0
  # revision: 1-9-0-1
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster2
      network: network2

  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
EOF

# c3
cat << EOF | kubectl --context c3-admin apply -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiocontrolplane-default
  namespace: istio-system
spec:
  hub: gcr.io/istio-release
  tag: 1.9.0
  # revision: 1-9-0-1
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster3
      network: network3

  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
EOF
```

## Deploy East-West Ingress GW 
```
istio-1.9.0/samples/multicluster/gen-eastwest-gateway.sh --mesh mesh1 --cluster cluster1 --network network1 | istioctl --context=c1-admin install -y -f -
istio-1.9.0/samples/multicluster/gen-eastwest-gateway.sh --mesh mesh1 --cluster cluster2 --network network2 | istioctl --context=c2-admin install -y -f -
istio-1.9.0/samples/multicluster/gen-eastwest-gateway.sh --mesh mesh1 --cluster cluster3 --network network3 | istioctl --context=c3-admin install -y -f -
```

## Expose Services on Clusters
```
kubectl --context=c1-admin apply -n istio-system -f ./istio-1.9.0/samples/multicluster/expose-services.yaml
kubectl --context=c2-admin apply -n istio-system -f ./istio-1.9.0/samples/multicluster/expose-services.yaml
kubectl --context=c3-admin apply -n istio-system -f ./istio-1.9.0/samples/multicluster/expose-services.yaml
```

## Deploy Remote Secret for Endpoint Discovery on Clusters
``` bash
# Deploy Remote Secret on c1 that provides >>Access to>> c2, c3 API Servers  || c1 >> c2, c3
./istio-1.9.0/bin/istioctl x create-remote-secret --context=c2-admin --name=cluster2 | kubectl apply -f - --context=c1-admin
./istio-1.9.0/bin/istioctl x create-remote-secret --context=c3-admin --name=cluster3 | kubectl apply -f - --context=c1-admin

# Deploy Remote Secret on c2 that provides >>Access to>> c1, c3 API Servers  || c2 >> c1, c3
./istio-1.9.0/bin/istioctl x create-remote-secret --context=c1-admin --name=cluster1 | kubectl apply -f - --context=c2-admin
./istio-1.9.0/bin/istioctl x create-remote-secret --context=c3-admin --name=cluster3 | kubectl apply -f - --context=c2-admin

# Deploy Remote Secret on c3 that provides >>Access to>> c2, c3 API Servers  || c3 >> c1, c2
./istio-1.9.0/bin/istioctl x create-remote-secret --context=c1-admin --name=cluster1 | kubectl apply -f - --context=c3-admin
./istio-1.9.0/bin/istioctl x create-remote-secret --context=c2-admin --name=cluster2 | kubectl apply -f - --context=c3-admin
```

