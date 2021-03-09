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

# You could also use topology.istio.io/subzone definition to define additional data about your node
# like rack, dc, pdu or special key about a node
# kubectl --context=c3-admin label nodes c3n3 --overwrite topology.istio.io/subzone=rack3
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

## Deploy Sample Pods for our tests
Deploy helloworld2 and sleep pods on all regions and zones. With help of these pods we could apply regional cross cluster scenarios on three clusters
``` bash
kubectl --context=c1-admin apply -f ./helloworld2-ns.yaml
kubectl --context=c2-admin apply -f ./helloworld2-ns.yaml
kubectl --context=c3-admin apply -f ./helloworld2-ns.yaml

kubectl --context=c1-admin apply -f ./helloworld2-c1.yaml
kubectl --context=c2-admin apply -f ./helloworld2-c2.yaml
kubectl --context=c3-admin apply -f ./helloworld2-c3.yaml

kubectl --context=c1-admin apply -n sample -f sleep-ns.yaml
kubectl --context=c2-admin apply -n sample -f sleep-ns.yaml
kubectl --context=c3-admin apply -n sample -f sleep-ns.yaml

kubectl --context=c1-admin apply -n sample -f sleep.yaml
kubectl --context=c2-admin apply -n sample -f sleep.yaml
kubectl --context=c3-admin apply -n sample -f sleep.yaml
```

# Cross Cluster Scenarios

## CC1: Check Basic Cross Cluster Communication
Here we send a request from C1 Cluster, sleepz2 pod(Region1, Zone2) to helloworld2 service
on sample namespace and we got replies from the pods on all clusters so cross cluster communication is working

``` bash
for count in `seq 1 50`; do
    kubectl exec --context=c1-admin -n sample -c sleep sleepz2 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c2z1, instance: helloworld2-c2z1-5df4555cd9-tkbtb
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
```

## CC2: Locality Aware Load Balancing
Here our aim is, Istio to use Locality Aware Prioritised Load Balancing. With the setup below our data stays under same zone and
it did not go to other zone until there is a problem or disaster on current zone.

First lets check that we got reply from all zones
``` bash
for count in `seq 1 5`; do
    kubectl exec --context=c1-admin -n sample -c sleep sleepz2 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
```

Apply below Virtual Service and Destination rule to activate locality aware load balancing, here below adding 
outlier detection is important to make it work, also one more thing there is no localityLBSetting below so data will remain on same zone.
This locality aware approach is important because Cloud Providers extra charge data which travels between zones while under same zone 
they do not charge anything extra.
``` bash
kubectl apply --context=c1-admin -n sample -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: helloworld2
spec:
  hosts:
    - helloworld2
  http:
  - route:
    - destination:
        host: helloworld2
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: helloworld2-loc1
spec:
  host: helloworld2
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 1s
      baseEjectionTime: 30s
EOF
```

Send same request again and you will notice that data stays on zone
``` bash
for count in `seq 1 5`; do
    kubectl exec --context=c1-admin -n sample -c sleep sleepz2 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
```

Lets simulate a disaster lets drain Envoy proxy on helloworld2-c1z2 pod and lets check which pods reply to our requests.
To drain a pod execute the command below. Here I am draining c1z2 pod, if you have reply from other pods you need to update the command below.
Drain pods take like a minute so you could query pod status to see pod ready is 1/2
``` bash
kubectl exec --context=c1-admin -n sample -c istio-proxy $(kubectl --context=c1-admin -n sample get pods -l version=c1z2,app=helloworld2 -o jsonpath='{.items[0].metadata.name}')  -- curl -sSL -X POST 127.0.0.1:15000/drain_listeners

# Check Drain progress
kubectl --context=c1-admin -n sample get pods -l version=c1z2,app=helloworld2
NAME                                READY   STATUS    RESTARTS   AGE
helloworld2-c1z2-69dfd5c6f4-q9ww4   1/2     Running   0          6d22h
```

Send same request again and you will notice that now we got replies from pods on different zones but in same cluster
``` bash
for count in `seq 1 5`; do
    kubectl exec --context=c1-admin -n sample -c sleep sleepz2 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
```

Cleanup Scenario
``` bash
kubectl exec --context=c1-admin -n sample -c istio-proxy $(kubectl --context=c1-admin -n sample get pods -l version=c1z2,app=helloworld2 -o jsonpath='{.items[0].metadata.name}')  -- /bin/sh -c "kill 1"
kubectl delete --context=c1-admin -n sample vs/helloworld2
kubectl delete --context=c1-admin -n sample dr/helloworld2-loc1
```

## CC3: Locality Weighted Distribution Load Balancing
Here our aim is, Istio to use Locality Weighted Distribution Load Balancing. With this setup we could redirect traffic from/to with a weighted distribution.
Like the traffic coming from region1 with a sample distribution like 30% to region 2 and 20% to region 3 and remaining to region4. So we could control traffic 
distribution between regions

First lets check that we got reply from all zones
``` bash
for count in `seq 1 5`; do
    kubectl exec --context=c2-admin -n sample -c sleep sleepz2 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c2z2, instance: helloworld2-c2z2-757dd89c66-7f4lw
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c2z3, instance: helloworld2-c2z3-7d557ff6d9-dvgmd
```

Apply below Virtual Service and Destination rule to activate weighted distribution load balancing
Here we got 3 rules below to control traffic on region2 (Cluster 2) 
On First Rule: Traffic coming from region2, zone1 distributed 50/50 to region1 and region3
On Second Rule traffic coming from region2 zone2 will be distributed to region2 and region3
On Third Rule traffic coming from region2 zone3 will be redirected all to region4, zone5 
``` bash
kubectl apply --context=c2-admin -n sample -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: helloworld2
  namespace: sample
spec:
  hosts:
    - helloworld2
  http:
  - route:
    - destination:
        host: helloworld2
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: helloworld2-loc2
  namespace: sample
spec:
  host: helloworld2.sample.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      localityLbSetting:
        enabled: true
        distribute:
        - from: region2/zone1/*
          to:
            "region1/*": 50
            "region3/*": 50
        - from: region2/zone2/*
          to:
            "region2/zone3/*": 40
            "region2/zone1/*": 40
            "region3/*": 20
        - from: region2/zone3/*
          to:
            "region4/zone5/*": 100
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
EOF
```

* For the first rule
``` bash
for count in `seq 1 10`; do
    kubectl exec --context=c2-admin -n sample -c sleep sleepz1 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c3z2, instance: helloworld2-c3z2-57dff95bbb-8nqvf
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c3z2, instance: helloworld2-c3z2-57dff95bbb-8nqvf
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c3z1, instance: helloworld2-c3z1-cdf788db9-xrjr7
Hello version: c3z2, instance: helloworld2-c3z2-57dff95bbb-8nqvf
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c3z2, instance: helloworld2-c3z2-57dff95bbb-8nqvf
```

* For the second rule
``` bash
for count in `seq 1 10`; do
    kubectl exec --context=c2-admin -n sample -c sleep sleepz2 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c2z1, instance: helloworld2-c2z1-5df4555cd9-tkbtb
Hello version: c2z3, instance: helloworld2-c2z3-7d557ff6d9-dvgmd
Hello version: c2z1, instance: helloworld2-c2z1-5df4555cd9-tkbtb
Hello version: c2z3, instance: helloworld2-c2z3-7d557ff6d9-dvgmd
Hello version: c2z1, instance: helloworld2-c2z1-5df4555cd9-tkbtb
Hello version: c2z1, instance: helloworld2-c2z1-5df4555cd9-tkbtb
Hello version: c2z3, instance: helloworld2-c2z3-7d557ff6d9-dvgmd
Hello version: c2z1, instance: helloworld2-c2z1-5df4555cd9-tkbtb
Hello version: c2z3, instance: helloworld2-c2z3-7d557ff6d9-dvgmd
Hello version: c2z3, instance: helloworld2-c2z3-7d557ff6d9-dvgmd
```

* For the third rule
``` bash
for count in `seq 1 10`; do
    kubectl exec --context=c2-admin -n sample -c sleep sleepz3 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
```

Cleanup Scenario
``` bash
kubectl delete --context=c2-admin -n sample vs/helloworld2
kubectl delete --context=c2-admin -n sample dr/helloworld2-loc2
```


## CC4: Locality Failover
Here our plan is to apply locality failover over cluster 2 to simulate a complete failure on region2 Region. When this failure occurs
packages coming from region4 will be redirected to region3. 

First lets send a request from region1 and check that region4 replies one or two of our requests. We need to get replies from c2z4 or c2z5 pods which are on region4
``` bash
for count in `seq 1 100`; do
    kubectl exec --context=c1-admin -n sample -c sleep sleepz3 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c3z2, instance: helloworld2-c3z2-57dff95bbb-8nqvf
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c1z1, instance: helloworld2-c1z1-59ccb7b69d-22gbt
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c1z3, instance: helloworld2-c1z3-8546875b76-jvrm7
Hello version: c1z2, instance: helloworld2-c1z2-69dfd5c6f4-q9ww4
```

Apply VR and DR to region4
``` bash
kubectl apply --context=c2-admin -n sample -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: helloworld2
  namespace: sample
spec:
  hosts:
    - helloworld2
  http:
  - route:
    - destination:
        host: helloworld2
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: helloworld2-loc-failover
  namespace: sample
spec:
  host: helloworld2.sample.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        maxRequestsPerConnection: 1
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failover:
          - from: region4
            to: region3
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 1m
EOF
```

Check that traffic stays on locally on same zone for region4
``` bash
for count in `seq 1 5`; do
    kubectl exec --context=c2-admin -n sample -c sleep sleepz4 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
Hello version: c2z4, instance: helloworld2-c2z4-6b575f445b-9bngd
``` 

To apply failover from region4 to region3 we drain helloworld2 listener on region4
``` bash
kubectl exec --context=c2-admin -n sample -c istio-proxy $(kubectl --context=c2-admin -n sample get pods -l version=c2z4,app=helloworld2 -o jsonpath='{.items[0].metadata.name}')  -- curl -sSL -X POST 127.0.0.1:15000/drain_listeners
```

Traffic redirected to the different zone on same region
``` bash
 for count in `seq 1 5`; do
    kubectl exec --context=c2-admin -n sample -c sleep sleepz4 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
Hello version: c2z5, instance: helloworld2-c2z5-5bd5d7b5b7-c7xkh
```

When we drain the helloworld2 pod on region4 zone5 this time traffic needs to be diverted to region3 services.
``` bash
kubectl exec --context=c2-admin -n sample -c istio-proxy $(kubectl --context=c2-admin -n sample get pods -l version=c2z5,app=helloworld2 -o jsonpath='{.items[0].metadata.name}')  -- curl -sSL -X POST 127.0.0.1:15000/drain_listeners
```

Check the traffic again in region4 you will see that its diverted to region3
``` bash
for count in `seq 1 5`; do
    kubectl exec --context=c2-admin -n sample -c sleep sleepz4 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c3z2, instance: helloworld2-c3z2-57dff95bbb-8nqvf
Hello version: c3z1, instance: helloworld2-c3z1-cdf788db9-xrjr7
Hello version: c3z3, instance: helloworld2-c3z3-bbd675db5-bvj7z
Hello version: c3z1, instance: helloworld2-c3z1-cdf788db9-xrjr7
```

Cleanup Scenario
``` bash
kubectl exec --context=c2-admin -n sample -c istio-proxy $(kubectl --context=c2-admin -n sample get pods -l version=c2z4,app=helloworld2 -o jsonpath='{.items[0].metadata.name}')  -- /bin/sh -c "kill 1"
kubectl exec --context=c2-admin -n sample -c istio-proxy $(kubectl --context=c2-admin -n sample get pods -l version=c2z5,app=helloworld2 -o jsonpath='{.items[0].metadata.name}')  -- /bin/sh -c "kill 1"
kubectl delete --context=c2-admin -n sample vs/helloworld2
kubectl delete --context=c2-admin -n sample dr/helloworld2-loc-failover
```

# Testing Istio DNS Proxy