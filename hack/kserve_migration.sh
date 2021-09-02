#!/bin/bash
# Usage: kserve_migration.sh

set -o errexit

export CONFIG_DIR="config"
export ISVC_CONFIG_DIR="${CONFIG_DIR}/isvc"
export KSVC_CONFIG_DIR="${CONFIG_DIR}/ksvc"

# TODO: Should be removed once kserve release version is ready
# Checks whether KO_DOCKER_REPO is set or not
if [ -z $KO_DOCKER_REPO ]; then
    echo "Please set KO_DOCKER_REPO variable"
    exit 1;
fi

# Validates whether controller manager and models web app service running 
# on this machine for the given namespace or not.
isControllerRunning() {
    namespace=$1
    prefix="kserve"
    if [ "${namespace}" == "kfserving-system" ]; then
        prefix="kfserving"
    fi
    svc_names=$(kubectl get svc -n $namespace -o jsonpath='{.items[*].metadata.name}')
    for svc_name in "${prefix}-controller-manager-metrics-service" \
                    "${prefix}-controller-manager-service" \
                    "${prefix}-models-web-app" \
                    "${prefix}-webhook-server-service"; do
        if [ ! -z "${svc_names##*$svc_name*}" ]; then
            echo "error: controller services are not installed completely."
            exit 1;
        fi
    done
    po_names=$(kubectl get po -n $namespace -o jsonpath='{.items[*].metadata.name}')
    for po_name in "${prefix}-controller-manager" "${prefix}-models-web-app"; do
        if [ ! -z "${po_names##*$po_name*}" ]; then
            echo "error: controller services are not installed completely."
            exit 1;
        fi
    done
}

# Checks whether the kfserving is running or not
isControllerRunning kfserving-system


# Get inference services config
echo "getting inference services config"
inference_services=$(kubectl get isvc -A -o jsonpath='{.items[*].metadata.namespace},{.items[*].metadata.name}')
echo "inference services: ${inference_services}"
declare -a isvc_names
declare -a isvc_ns
if [ ! -z "$inference_services" ]; then
    mkdir -p ${ISVC_CONFIG_DIR}
    IFS=','; isvc_split=($inference_services); unset IFS;
    isvc_ns=(${isvc_split[0]})
    isvc_names=(${isvc_split[1]})
fi
isvc_count=${#isvc_names[@]}
for (( i=0; i<${isvc_count}; i++ ));
do
    kubectl get isvc ${isvc_names[$i]} -n ${isvc_ns[$i]} -o yaml > "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml"
done

# Get knative services names
echo "getting knative services"
knative_services=$(kubectl get ksvc -A -o jsonpath='{.items[*].metadata.namespace},{.items[*].metadata.name}')
echo "knative services: ${knative_services}"
declare -a ksvc_names;
declare -a ksvc_ns;
if [ ! -z "$knative_services" ]; then
    mkdir -p ${KSVC_CONFIG_DIR}
    IFS=','; ksvc_split=(${knative_services}); unset IFS;
    ksvc_ns=(${ksvc_split[0]})
    ksvc_names=(${ksvc_split[1]})
fi
ksvc_count=${#ksvc_names[@]}

if [ $isvc_count != $ksvc_count ]; then
    echo "error: inference and knative services counts should be equal."
    exit 1;
fi

# Deploy kserve
echo "deploying kserve"
cd ..
# TODO: once release version is ready, deploy kserve from release version config.
# for i in 1 2 3 4 5 ; do kubectl apply -f install/${KSERVE_VERSION}/kfserving.yaml && break || sleep 15; done
make deploy-dev
kubectl wait --for=condition=ready --timeout=120s po --all -n kserve
isControllerRunning kserve
cd hack
echo "kserve deployment completed"

# Remove owner references from knative services
echo "removing owner references from knative services"
declare -A ksvc_isvc_map
for (( i=0; i<${ksvc_count}; i++ ));
do
    ksvc_isvc_map[${ksvc_names[$i]}]=$(kubectl get ksvc ${ksvc_names[$i]} -n ${ksvc_ns[$i]} -o json | jq --raw-output '.metadata.ownerReferences[0].name')
    kubectl patch ksvc ${ksvc_names[$i]} -n ${ksvc_ns[$i]} --type json -p='[{"op": "remove", "path": "/metadata/ownerReferences"}]'
done
sleep 5

# Deploy inference services on kserve
echo "deploying inference services on kserve"
sed -i -- 's/kubeflow.org/kserve.io/g' ${ISVC_CONFIG_DIR}/*
for (( i=0; i<${isvc_count}; i++ ));
do
    yq d -i "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml" 'metadata.annotations'
    yq d -i "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml" 'metadata.creationTimestamp'
    yq d -i "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml" 'metadata.finalizers'
    yq d -i "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml" 'metadata.generation'
    yq d -i "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml" 'metadata.resourceVersion'
    yq d -i "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml" 'metadata.uid'
    yq d -i "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml" 'status'
    kubectl apply -f "${ISVC_CONFIG_DIR}/${isvc_names[$i]}.yaml"
done
sleep 300

# Extract inference service uids
echo "extracting inference service uids"
declare -A infr_uid_map
for (( i=0; i<${isvc_count}; i++ ));
do
    infr_uid_map[${isvc_names[$i]}]=$(kubectl get isvc ${isvc_names[$i]} -n ${isvc_ns[$i]} -o json | jq --raw-output '.metadata.uid')
done

# Update knative services with new owner reference
echo "updating knative services with new owner reference"
for (( i=0; i<${ksvc_count}; i++ ));
do
    isvc_name=${ksvc_isvc_map[${ksvc_names[$i]}]}
    isvc_uid=${infr_uid_map[${isvc_name}]}
    kubectl patch ksvc ${ksvc_names[$i]} -n ${ksvc_ns[$i]} --type='json' -p='[{"op": "add", "path": "/metadata/ownerReferences", "value": [{"apiVersion": "serving.kserve.io/v1beta1","blockOwnerDeletion": true,"controller": true,"kind": "InferenceService","name": "'${isvc_name}'","uid": "'${isvc_uid}'"}] }]'
done
sleep 5

# Delete inference services running on kfserving
echo "deleting inference services on kfserving"
for (( i=0; i<${isvc_count}; i++ ));
do
    kubectl delete inferenceservice.serving.kubeflow.org ${isvc_names[$i]} -n ${isvc_ns[$i]}
done

# Update apiversion in knative services
echo "updating apiversion in knative services"
for (( i=0; i<${ksvc_count}; i++ ));
do
    kubectl get ksvc ${ksvc_names[$i]} -n ${ksvc_ns[$i]} -o yaml > "${KSVC_CONFIG_DIR}/${ksvc_names[$i]}.yaml"
    sed -i -- 's/kubeflow.org/kserve.io/g' "${KSVC_CONFIG_DIR}/${ksvc_names[$i]}.yaml"
    kubectl apply -f "${KSVC_CONFIG_DIR}/${ksvc_names[$i]}.yaml"
done

# Clean up kfserving
echo "deleting kfserving namespace"
kubectl delete ns kfserving-system
rm -rf ${CONFIG_DIR}

echo "kserve migration completed successfully"
exit 0;
