
NAMESPACE=$1

NFS_POD_NAME=$(kubectl --kubeconfig=$BENCHMARK_DIR/kubeconfig get pods -l role=kubebench-nfs -o jsonpath="{.items[0].metadata.name}")

kubectl --kubeconfig=$BENCHMARK_DIR/kubeconfig cp /tmp/mpi-job-1.yaml ${NAMESPACE}/${NFS_POD_NAME}:/exports/kubebench/config/mpi/
kubectl --kubeconfig=$BENCHMARK_DIR/kubeconfig cp /tmp/mpi-job-2.yaml ${NAMESPACE}/${NFS_POD_NAME}:/exports/kubebench/config/mpi/
kubectl --kubeconfig=$BENCHMARK_DIR/kubeconfig cp /tmp/mpi-job-4.yaml ${NAMESPACE}/${NFS_POD_NAME}:/exports/kubebench/config/mpi/
kubectl --kubeconfig=$BENCHMARK_DIR/kubeconfig cp /tmp/mpi-job-8.yaml ${NAMESPACE}/${NFS_POD_NAME}:/exports/kubebench/config/mpi/

BENCHMARK_ID=$(basename $BENCHMARK_DIR)
aws s3 cp ${BENCHMARK_DIR}/ s3://${S3_BUCKET}/${BENCHMARK_ID}/ --recursive