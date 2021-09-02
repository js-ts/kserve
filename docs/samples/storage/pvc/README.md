
# Create a InferenceService for on-prem cluster

The guide shows how to train model and create InferenceService for the trained model for on-prem cluster.

## Prerequisites
Refer to the [document](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) to create Persistent Volume (PV) and Persistent Volume Claim (PVC), the PVC will be used to store model.

## Training model

Follow the mnist example [guide](https://github.com/kubeflow/fairing/blob/master/examples/mnist/mnist_e2e_on_prem.ipynb) to train a mnist model and store it to PVC. The InferenceService is deployed in the notebook example by `Kubeflow Fairing` that uses `kserve` SDK. If you want to apply the InferenceService via kubectl by using the YAML format as below, no need to run the deployment step in the notebook. In this example, the relative path of model will be `./export/` on the PVC.

## Create the InferenceService

Update the ${PVC_NAME} to the created PVC name in the `mnist-pvc.yaml` and apply:
```bash
kubectl apply -f mnist-pvc.yaml
```

Expected Output
```
$ inferenceservice.serving.kserve.io/mnist-sample configured
```

## Check the InferenceService

```bash
$ kubectl get inferenceservice
NAME               URL                                           READY   PREV   LATEST   PREVROLLEDOUTREVISION   LATESTREADYREVISION                        AGE
mnist-sample   http://mnist-sample.default.example.com   True           100                              mnist-sample-predictor-default-00001   1m
```
