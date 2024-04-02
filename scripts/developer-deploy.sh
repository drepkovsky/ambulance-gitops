#!/bin/bash

# Default values
cluster=${1:-"localhost"}
namespace=${2:-"wac-hospital"}
installFlux=${3:-true}

ProjectRoot="$PSSCRIPTROOT/.."
echo "ScriptRoot is $PSSCRIPTROOT"
echo "ProjectRoot is $ProjectRoot"

clusterRoot="$ProjectRoot/clusters/$cluster"

set -e  # Equivalent to $ErrorActionPreference = "Stop"

context=$(kubectl config current-context)

# Checking PowerShell version is not applicable in Bash
# PowerShell version check is skipped

# Check if `sops` command is available
if ! command -v sops &> /dev/null; then
    echo "sops CLI must be installed. Please install it before continuing."
    exit -11
fi
sopsVersion=$(sops -v)

# Check if $cluster folder exists
if [ ! -d "$clusterRoot" ]; then
    echo "Cluster folder $cluster does not exist"
    exit -12
fi

# Display banner
banner="THIS IS A FAST DEPLOYMENT SCRIPT FOR DEVELOPERS!
---
The script shall be running **only on fresh local cluster**!
After initialization, it **uses gitops** controlled by installed flux cd controller.
To do some local fine tuning get familiarized with flux, kustomize, and kubernetes

Verify that your context is corresponding to your local development cluster:

* Your kubectl *context* is **$context**.
* You are installing *cluster* **$cluster**.
* *Mozilaa SOPS* version is **$sopsVersion**.
* You got *private SOPS key* for development setup."

echo "$banner"

read -p "Are you sure to continue? (y/n) " correct
if [ "$correct" != "y" ]; then
    echo "Exiting script due to user selection."
    exit -1
fi

# Function to read password
read_password() {
    prompt=${1:-"Password"}
    defaultPassword=${2:-""}
    echo -n "${prompt} [${defaultPassword}]: "
    read -s password
    echo
    if [ -z "$password" ]; then
        password=$defaultPassword
    fi
    echo $password
}

agekey=$(read_password "Enter master key of SOPS AGE (for developers)")

# Create a namespace
echo "Creating namespace $namespace"
kubectl create namespace $namespace
echo "Created namespace $namespace"

# Generate AGE key pair and create a secret for it
echo "Creating sops-age private secret in the namespace ${namespace}"
kubectl delete secret sops-age --namespace "${namespace}" --ignore-not-found=true
kubectl create secret generic sops-age --namespace "${namespace}" --from-literal=age.agekey="$agekey"
echo "Created sops-age private secret in the namespace ${namespace}"

# Unencrypt gitops-repo secrets to push it into cluster
echo "Creating gitops-repo secret in the namespace ${namespace}"
patSecret="$clusterRoot/secrets/params/repository-pat.env"
if [ ! -f "$patSecret" ]; then
    patSecret="$clusterRoot/../localhost/secrets/params/gitops-repo.env"
    if [ ! -f "$patSecret" ]; then
        echo "gitops-repo secret not found in $clusterRoot/secrets/params/gitops-repo.env or $clusterRoot/../localhost/secrets/params/gitops-repo.env"
        exit -13
    fi
fi

oldKey=$SOPS_AGE_KEY
export SOPS_AGE_KEY=$agekey
envs=$(sops --decrypt $patSecret)
if [ $? -ne 0 ]; then
    echo "Failed to decrypt gitops-repo secret"
    exit -14
fi

# Read environments from env
username=$(echo "$envs" | awk -F '=' '/^username/ {print $2}')
password=$(echo "$envs" | awk -F '=' '/^password/ {print $2}')

export SOPS_AGE_KEY="$oldKey"
agekey=""
kubectl delete secret repository-pat --namespace $namespace --ignore-not-found=true
kubectl create secret generic repository-pat --namespace $namespace --from-literal=username="$username" --from-literal=password="$password"

username=""
password=""
echo "Created gitops-repo secret in the namespace ${namespace}"

if [ "$installFlux" = true ]; then
    echo "Deploying the Flux CD controller"
    kubectl apply -k "$ProjectRoot/infrastructure/fluxcd" --wait
    echo "Flux CD controller deployed"
fi

echo "Deploying the cluster manifests"
kubectl apply -k "$clusterRoot" --wait
echo "Bootstrapping process is done, check the status of the GitRepository and Kustomization resource in namespace ${namespace} for reconciliation updates"
