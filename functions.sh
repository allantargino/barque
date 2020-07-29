function ensure_dependencies(){
  az extension add --name azure-devops
  # TODO: kubectl
  # TODO: docker
  # TODO: kind
  # TODO: clusterctl
}

function create_repo() {
  local appname=$1
  shift
  local orgAndproj=("$@")

  if ! az repos show -r $appname "${orgAndproj[@]}" 2>/dev/null; then
    az repos create --name $appname "${orgAndproj[@]}"
  else
    echo "repo $appname already exists"
  fi
}

function configure_app_repo() {
  local appname=$1
  local devopsorg=$2
  local APP_GIT="$3"
  local workflow_strategy=$4
  local manifestlive=$5
  shift 5
  local orgAndproj=("$@")
  
  workdir=$(pwd)
  echo $workdir
  REPO_HOME=$(mktemp -d)
  pushd $REPO_HOME
  sshurl=$(az repos show -r $appname "${orgAndproj[@]}" --query 'sshUrl' -o tsv)
  git clone $sshurl

  #TODO check if dir already has files... don't want to overwrite any customizations. Maybe show diff?
  mkdir $appname/.azuredevops/ || true
  cp -r "$workdir"/workflow-strategies/$workflow_strategy/pipelines/* $appname/.azuredevops/

  # terrible hack becuase cannot use ${{ parameters.manifestRepo }} as there is a bug "An error occurred while loading the YAML build pipeline. An item with the same key has already been added."
  sed -i -e "s#git://gitops/manifest-live#git://$devopsorg/$manifestlive#g" $appname/.azuredevops/templates/automatic-release-template.yaml

  pushd $appname
  git add .
  git commit -m "copy files over" || true #ignore failure
  git remote add upstream $APP_GIT
  git fetch upstream
  git rebase upstream/master

  ## will fail on re-run after build policy is in place.  should remove then update then re-apply
  git push origin master
  echo "finished"
  popd
  popd
}

function configure_manifest_repo() {
  local appname=$1
  local devopsorg=$2
  local workflow_strategy=$3
  local sample=$4
  shift 4
  local orgAndproj=("$@")

  workdir="$(pwd)"
  echo $workdir
  REPO_HOME=$(mktemp -d)
  pushd $REPO_HOME
  sshurl=$(az repos show -r $appname "${orgAndproj[@]}" --query 'sshUrl' -o tsv)
  git clone $sshurl
  
  #TODO check if dir already has files... don't want to overwrite any customizations. Maybe show diff?
  cp -rT "$workdir"/workflow-strategies/$workflow_strategy/manifest/ $appname/

  # remove sample if necessary
  if [[ "$sample" = false ]]; then 
    rm -rf `find -type d -name sample-*`
  fi

  pushd $appname
  git add .
  git commit -m "copy files over" || true #ignore failure

  ## will fail on re-run after build policy is in place.  should remove then update then re-apply
  git push origin master
  echo "finished"
  popd
  popd
}

function add_pipeline_variable() {
  local pipeline=$1
  local name=$2
  local value=$3
  shift 3
  local orgAndproj=("$@")
  
  PIPELINE_EXISTS=$(az pipelines list --name "${pipeline}" "${orgAndproj[@]}" --query '[].{id:id}' -o tsv)
  if [[ -z "$PIPELINE_EXISTS" ]]; then
    echo "please create the pipeline first"
    exit 1
  fi
  if az pipelines variable create --pipeline-id $PIPELINE_ID --name $name --value $value "${orgAndproj[@]}"; then 
    echo "Added ${name} : ${value} to $PIPELINE_ID"
  else
    echo "Updating ${name} : ${value} to $PIPELINE_ID"
    az pipelines variable update --pipeline-id $PIPELINE_ID --name $name --value $value "${orgAndproj[@]}"
  fi
}

function register_app_pipeline(){
  local appname=$1
  local pipeline=$2
  local filename=$3
  shift 3
  local orgAndproj=("$@")

  # create the pipeline, skip if already exists
  PIPELINE_ID=$(az pipelines list --name "${pipeline}" "${orgAndproj[@]}" --query '[].{id:id}' -o tsv)
  if [[ -z "$PIPELINE_ID" ]]; then 
    echo "Creating pipeline now "
    PIPELINE_ID=$(az pipelines create --skip-first-run --branch master --name "${pipeline}" --description "${pipeline} automatically generated via Barque" --repository-type tfsgit --repository $appname --yml-path "/.azuredevops/user-pipelines/${filename}" "${orgAndproj[@]}" --query 'id' -o tsv)
  else
    echo "${pipeline} already exists"
  fi
}

function trigger_pipeline() {
  local pipeline=$1
  shift;
  local orgAndproj=("$@")
  PIPELINE_ID=$(az pipelines list --name "${pipeline}" "${orgAndproj[@]}" --query '[].{id:id}' -o tsv)
  az pipelines build queue --definition-id $PIPELINE_ID "${orgAndproj[@]}"
}

function apply_pr_policy() {
  local appname=$1
  local project=$2
  local pipeline=$3
  shift 3
  local orgAndproj=("$@")

  REPO_ID=$(az repos show -r $appname "${orgAndproj[@]}" --query 'id' -o tsv)
  PIPELINE_ID=$(az pipelines list --name "${pipeline}" "${orgAndproj[@]}" --query '[].{id:id}' -o tsv)
  # apply pr policy 
  # https://docs.microsoft.com/en-us/azure/devops/cli/policy-configuration-file?view=azure-devops
  temp_file=$(mktemp)
  sed -e "s/BUILD_DEFINITION_ID/$PIPELINE_ID/g" ./workflow-strategies/pr-policy.json > $temp_file
  sed -i -e "s/REPO_ID/$REPO_ID/g" $temp_file
  policy=$( az repos policy list --branch master --repository-id $REPO_ID "${orgAndproj[@]}" --query "[?settings.displayName=='PR build policy'].{id:id}" -o tsv)
  if [[ -z "$policy"  ]]; then
    az repos policy create --policy-configuration $temp_file "${orgAndproj[@]}"
  else
    echo "policy exists $policy"
  fi
}

function setup_service_connection() {
  local appname=$1
  local project=$2
  local acrname=$3
  local devopsorg=$4
  local pipeline=$5
  local service_connection_name=$6
  shift 6
  local orgAndproj=("$@")
  
  tenant_id=$(az account show --query 'tenantId' -o tsv)
  sub_id=$(az account show --query 'id' -o tsv)
  sub_name=$(az account show --query 'name' -o tsv)
  scope=$(az acr show -n $acrname --query "id" -o tsv)
  PIPELINE_ID=$(az pipelines list --name "${pipeline}" "${orgAndproj[@]}" --query '[].{id:id}' -o tsv)
  
  # apply service endpoint
  temp_file=$(mktemp)
  sed -e "s/TENANT_ID/$tenant_id/g; s/SUB_ID/$sub_id/g; s/SUB_NAME/$sub_name/g; s/SERVICE_CONNECTION_NAME/$service_connection_name/g; s#ACR_ID#$scope#g" ./workflow-strategies/arm-service-connection.json > $temp_file
  echo "TEMP_FILE: ${temp_file}"

  serviceendpoint=$(az devops service-endpoint list "${orgAndproj[@]}" --query "[?name=='$service_connection_name'].{id:id}" -o tsv)
  echo "The serviceendpoint is: ${serviceendpoint}"
  if [[ -z "$serviceendpoint" ]]; then
    echo "Trying to create new service endpoint"
    # https://docs.microsoft.com/en-us/azure/devops/cli/service_endpoint?view=azure-devops#create-service-endpoint-using-configuration-file
    serviceendpoint=$(az devops service-endpoint create "${orgAndproj[@]}" --service-endpoint-configuration $temp_file --query 'id' -o tsv)
  else
    echo "serviceendpoint exists $serviceendpoint"
  fi

  # authorize pipelines to use service connection
  # PATCH https://dev.azure.com/{org}/{project}/_apis/pipelines/pipelinePermissions/endpoint/{serviceConnectionId}?api-version=5.1-preview
  # routeTemplate: {project}/_apis/pipelines/{resource}/{resourceType}/{resourceId}
  temp_file=$(mktemp)
  sed -e "s/PIPELINE_ID/$PIPELINE_ID/g;" ./workflow-strategies/pipeline-service-connection-auth.json > $temp_file
  az devops invoke --organization $devopsorg --area pipelinePermissions --resource pipelinePermissions --route-parameters project=$project resourceType=endpoint resourceId=$serviceendpoint --http-method PATCH --api-version 5.1-preview  --in-file $temp_file -o json
}

function set_build_agent_permission() {
  local org=$1
  local project=$2
  local manifestlive=$3
  shift 3
  local orgAndproj=("$@")
  
  # these are require to scop permissions to manifest-live repo 
  # its also possible to go down to the branch level!
  projectid=$(az devops project show "${orgAndproj[@]}" --query "id" -o tsv)
  repoid=$(az repos show -r $manifestlive "${orgAndproj[@]}" --query "id" -o tsv)
  # format of service name from: https://docs.microsoft.com/en-us/azure/devops/pipelines/build/options?view=azure-devops#scoped-build-identities
  buildagentname="$project Build Service ($org)"
  
  ##### IMPORTANT#####
  # don't pass the project to following commands since running at org scope
  # build agent services get added to 'Security Service Group' group
  # must pass detect --false: https://stackoverflow.com/questions/54687597/azure-cli-az-devops-configure-defaults-has-no-effect-what-am-i-missing/54922935#54922935
  groupdescriptor=$(az devops security group list --detect false --organization https://dev.azure.com/$org --scope organization --query "graphGroups[?contains(displayName,'Security Service Group')].{descriptor: descriptor}" -o tsv)
  buildagentdescriptor=$(az devops security group membership list --detect false --organization https://dev.azure.com/$org --id $groupdescriptor --query "*.{dis: displayName, descriptor: descriptor}[?dis=='$buildagentname'].descriptor" -o tsv)
  
  # view repo permission by running: 
  #   az devops security permission namespace list --query "[?namespaceId=='2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87']"
  # permissions for contributor 4
  # namespace-id from: https://docs.microsoft.com/en-us/azure/devops/cli/security_tokens?view=azure-devops#namespace-name---git-repositories
  az devops security permission update --detect false --organization https://dev.azure.com/$org --namespace-id 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87 --subject $buildagentdescriptor --token "repoV2/$projectid/$repoid" --allow-bit 4
  # permission for prs 16384
  az devops security permission update --detect false --organization https://dev.azure.com/$org --namespace-id 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87 --subject $buildagentdescriptor --token "repoV2/$projectid/$repoid" --allow-bit 16384
  # permission for create branch 16
  az devops security permission update --detect false --organization https://dev.azure.com/$org --namespace-id 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87 --subject $buildagentdescriptor --token "repoV2/$projectid/$repoid" --allow-bit 16
}

function create_bootstrap_cluster(){
  local bootstrapClusterName=$1
  local infrastructureProvider=$2

  if kind get clusters | grep -w $bootstrapClusterName; then
    kind get kubeconfig --name $bootstrapClusterName > $bootstrapClusterName.kubeconfig
  else
    kind create cluster --name $bootstrapClusterName --kubeconfig $bootstrapClusterName.kubeconfig --wait 60s
  fi

  if ! kubectl get providers --all-namespaces --kubeconfig=./$bootstrapClusterName.kubeconfig | grep infrastructure-$infrastructureProvider; then
    clusterctl init --infrastructure $infrastructureProvider --kubeconfig $bootstrapClusterName.kubeconfig
    kubectl wait --for=condition=Ready pods --all --all-namespaces --kubeconfig $bootstrapClusterName.kubeconfig --timeout=2m
  fi

}

function create_workload_cluster(){
  local managementClusterName=$1
  local workloadClusterName=$2
  local infrastructureProvider=$3


  if ! kubectl get cluster $workloadClusterName --kubeconfig=./$managementClusterName.kubeconfig; then
    echo Creating workload cluster...

    clusterctl config cluster $workloadClusterName --infrastructure $infrastructureProvider --kubeconfig=./$managementClusterName.kubeconfig \
      --kubernetes-version v1.17.3 --control-plane-machine-count=1 --worker-machine-count=1 > $workloadClusterName.temp.yaml
    
    kubectl apply --kubeconfig=./$managementClusterName.kubeconfig -f $workloadClusterName.temp.yaml    
  fi
  
  echo "Waiting for $workloadClusterName control plane to be ready..."
  kubectl wait --kubeconfig=./$managementClusterName.kubeconfig --for=condition=Ready cluster/management-cluster --timeout=15m
  
  kubectl get secret/$workloadClusterName-kubeconfig --namespace=default --kubeconfig=./$managementClusterName.kubeconfig -o jsonpath={.data.value} \
    | base64 --decode \
    > ./$workloadClusterName.kubeconfig

  if [[ $infrastructureProvider == "azure" ]] && ! kubectl get crds --kubeconfig management-cluster.kubeconfig | grep projectcalico.org; then
    kubectl --kubeconfig=./$workloadClusterName.kubeconfig \
      apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-azure/master/templates/addons/calico.yaml
    
    kubectl wait --for=condition=Ready pods --all --all-namespaces --kubeconfig $workloadClusterName.kubeconfig --timeout=2m
  fi
  # TODO: Install Calico/CNI solution on other providers
}

function create_management_cluster(){
  local bootstrapClusterName=$1
  local infrastructureProvider=$2

  MANAGEMENT_CLUSTER_NAME="management-cluster"

  create_workload_cluster $bootstrapClusterName $MANAGEMENT_CLUSTER_NAME $infrastructureProvider

  if ! kubectl get providers --all-namespaces --kubeconfig=./$MANAGEMENT_CLUSTER_NAME.kubeconfig | grep infrastructure-$infrastructureProvider; then
    echo Installing Cluster API...
    clusterctl init --infrastructure $infrastructureProvider --kubeconfig $MANAGEMENT_CLUSTER_NAME.kubeconfig

    kubectl wait --for=condition=Ready pods --all --all-namespaces --kubeconfig $MANAGEMENT_CLUSTER_NAME.kubeconfig --timeout=60s
  fi
}
