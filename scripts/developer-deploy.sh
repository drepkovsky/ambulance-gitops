#!/bin/zsh

# Default parameters
cluster="$1"
namespace="$2"
installFlux="${3:-true}"

# Set default values if parameters are not provided
[[ -z "$cluster" ]] && cluster="localhost"
[[ -z "$namespace" ]] && namespace="wac-hospital"

# Determine the script and project root directories
ScriptRoot=$(dirname "$(realpath "$0")")
ProjectRoot="$ScriptRoot/.."
echo "ScriptRoot is $ScriptRoot"
echo "ProjectRoot is $ProjectRoot"

clusterRoot="$ProjectRoot/clusters/$cluster"

# Error handling preference
set -e

# Check current kubectl context
context=$(kubectl config current-context)
echo "Current kubectl context is $context"

# Check for minimum required zsh version, adjust the version requirement as per your environment
if [[ ${ZSH_VERSION[1]} -lt 5 ]]; then
  echo "zsh version must be minimum of 5, please update your zsh. Current Version is $ZSH_VERSION"
  exit 10
fi

# Check if sops is installed
if ! command -v sops &>/dev/null; then
  echo "sops CLI must be installed, use 'brew install sops' to install it before continuing."
  exit 11
fi

sopsVersion=$(sops -v)
echo "Mozilla SOPS version is $sopsVersion"

# Check if cluster directory exists
if [[ ! -d "$clusterRoot" ]]; then
  echo "Cluster folder $cluster does not exist"
  exit 12
fi

# Display script information
cat <<EOF
THIS IS A FAST DEPLOYMENT SCRIPT FOR DEVELOPERS!
---

The script shall be running **only on fresh local cluster** **!
After initialization, it **uses gitops** controlled by installed flux cd controller.
To do some local fine tuning get familiarized with flux, kustomize, and kubernetes

Verify that your context is corresponding to your local development cluster:

* Your kubectl *context* is **$context**.
* You are installing *cluster* **$cluster**.
* *zsh* version is **$ZSH_VERSION**.
* *Mozilla SOPS* version is **$sopsVersion**.
* You got *private SOPS key* for development setup.
EOF

read -q "correct?Do you want to continue? [y/n]: "
if [[ "$correct" != "y" ]]; then
  echo "Exiting script due to the user selection"
  exit 1
fi

# read agekey
read -s "agekey?Enter your private SOPS key: "

if [[ -z "$agekey" ]]; then
  echo "Private SOPS key is required to continue"
  exit 2
fi
echo "Private SOPS key is provided"

# Create a namespace
echo "Creating namespace $namespace"
kubectl create namespace $namespace
echo "Created namespace $namespace"

# Generate AGE key pair and create a secret for it
echo "Creating sops-age private secret in the namespace $namespace"
kubectl delete secret sops-age --namespace "$namespace" 2>/dev/null
kubectl create secret generic sops-age --namespace "$namespace" --from-literal=age.agekey="$agekey"
echo "Created sops-age private secret in the namespace $namespace"

# Decrypt gitops-repo secrets to push it into the cluster
echo "Creating gitops-repo secret in the namespace $namespace"
patSecret="$clusterRoot/secrets/params/repository-pat.env"
if [[ ! -f "$patSecret" ]]; then
  patSecret="$clusterRoot/../localhost/secrets/params/gitops-repo.env"
  if [[ ! -f "$patSecret" ]]; then
    echo "gitops-repo secret not found in $clusterRoot/secrets/params/gitops-repo.env or $clusterRoot/../localhost/secrets/params/gitops-repo.env"
    exit 13
  fi
fi

oldKey=$SOPS_AGE_KEY
export SOPS_AGE_KEY=$agekey
envs=$(sops --decrypt $patSecret)

# Check for error exit code
if [[ $? -ne 0 ]]; then
  echo "Failed to decrypt gitops-repo secret"
  exit 14
fi

# Process the decrypted environment variables
username=$(echo "$envs" | grep -e '^username=' | cut -d '=' -f2)
password=$(echo "$envs" | grep -e '^password=' | cut -d '=' -f2)

export SOPS_AGE_KEY="$oldKey"
agekey=""
kubectl delete secret repository-pat --namespace $namespace 2>/dev/null
kubectl create secret generic repository-pat \
  --namespace $namespace \
  --from-literal username="$username" \
  --from-literal password="$password"

username=""
password=""
echo "Created gitops-repo secret in the namespace $namespace"

if [[ "$installFlux" == "true" ]]; then
  echo "Deploying the Flux CD controller"
  # First ensure CRDs exists when applying the repos
  kubectl apply -k $ProjectRoot/infrastructure/fluxcd --wait

  if [[ $? -ne 0 ]]; then
    echo "Failed to deploy fluxcd"
    exit 15
  fi

  echo "Flux CD controller deployed"
fi

echo "Deploying the cluster manifests"
kubectl apply -k $clusterRoot --wait
echo "Bootstrapping process is done, check the status of the GitRepository and Kustomization resource in namespace $namespace for reconciliation updates"
