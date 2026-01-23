# vagrant_k8s

Kubernetes VM for test (w/o GPUs)

## 1. Installation
Requires the installation of the tools [Vagrant](https://developer.hashicorp.com/vagrant) and a [VMware provider](https://developer.hashicorp.com/vagrant/docs/providers/vmware/installation).


## 2. Start 
```
vagrant up

vagrant ssh kube-control-plane

vagrant destroy
```