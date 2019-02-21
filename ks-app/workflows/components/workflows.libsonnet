{
  awsParams:: {
    //  Name of the k8s secrets containing S3 credentials
    awsSecretName: "",
    // Name of the key in the k8s secret containing AWS_ACCESS_KEY_ID.
    awsSecretAccesskeyidKeyName: "AWS_ACCESS_KEY_ID",
    // Name of the key in the k8s secret containing AWS_SECRET_ACCESS_KEY.
    awsSecretSecretaccesskeyKeyName: "AWS_SECRET_ACCESS_KEY",
    // S3 region
    awsRegion: "us-west-2",
    // true Whether or not to use https for S3 connections
    s3UseHttps: "true",
    // Whether or not to verify https certificates for S3 connections
    s3VerifySsl: "true",
    // URL for your s3-compatible endpoint.
    s3Endpoint: "s3.us-west-1.amazonaws.com",
  },
  
  githubParam:: {
    githubSecretName: "",
    githubSecretTokenKeyName: "GITHUB_TOKEN",
  },

  // The name of test cluster
  //local clusterName = "kubebench-e2e-" + std.substr(name, std.length(name) - 4, 4),
  // The Kubernetes version of test cluster
  local clusterVersion = "1.11",

  new(_env, _params):: {
    local params = _params + _env,

    // Fixed names won't change. Doesn't need to be passed from params
    // mountPath is the directory where the volume to store the test data
    // should be mounted.
    local mountPath = "/mnt/benchmark",
    // benchmarkDir is the root directory for all data for a particular test run.
    local benchmarkDir = mountPath + "/" + params.name,
    // benchmarkOutputDir is the directory to sync to GCS to contain the output for this job.
    local benchmarkOutputDir = benchmarkDir + "/output",
    local benchmarkArtifactsDir =  benchmarkOutputDir + "/artifacts",
    // Source directory where all repos should be checked out
    local benchmarkSrcRootDir = benchmarkDir + "/src",
    local benchmarkKubeConfigPath = benchmarkDir + "/kubeconfig",
    local srcDir = benchmarkSrcRootDir + "/jeffwan/ml-benchmark",
    // The directory containing the py scripts for testing
    local srcTestPyDir = srcDir + "/src",
    // The directory within the kubeflow_testing submodule containing
    // py scripts to use.
    local srcKubeTestPyDir = benchmarkSrcRootDir + "/kubeflow/testing/py",
    // The name of the NFS volume claim to use for test files.
    // local nfsVolumeClaim = "kubeflow-testing";
    local nfsVolumeClaim = params.nfsVolumeClaim,
    // The name to use for the volume to use to contain test data.
    local dataVolume = params.nfsVolume,

    // Optional
    local placementGroup = if params.placementGroup == "true" then 
      "--placement_group"
    else 
      "--no-placement_group",

    local aws_credential_env = [
      {
          name: "AWS_ACCESS_KEY_ID",
          valueFrom: {
            secretKeyRef: {
              name: params.s3SecretName,
              key: params.s3SecretAccesskeyidKeyName,
            },
          },
        },
        {
          name: "AWS_SECRET_ACCESS_KEY",
          valueFrom: {
            secretKeyRef: {
              name: params.s3SecretName,
              key: params.s3SecretSecretaccesskeyKeyName,
            },
          },
        },
    ],

    local github_token_env = [
      {
        name: "GITHUB_TOKEN",
        valueFrom: {
          secretKeyRef: {
            name: params.githubSecretName,
            key: params.githubSecretTokenKeyName,
          },
        },
      }
    ],

    // Build an Argo step template to execute a particular command.
    // step_name: Name for the template
    // command: List to pass as the container command.
    buildTemplate(step_name, command, envVars=[], sidecars=[], workingDir=null, kubeConfig="config"):: {
      name: step_name,
      container: {
        command: command,
        image: params.image,
        [if workingDir != null then "workingDir"]: workingDir,
        env: [
          {
            name: "BENCHMARK_DIR",
            value: benchmarkDir
          },
          {
            // Add the source directories to the python path.
            name: "PYTHONPATH",
            value: srcTestPyDir + ":" + srcKubeTestPyDir,
          },
          {
            // We use a directory in our NFS share to store our kube config.
            // This way we can configure it on a single step and reuse it on subsequent steps.
            // make sure it works with aws-k8s-tester
            name: "KUBECONFIG",
            value: benchmarkKubeConfigPath,
          },
        ] + envVars,
        volumeMounts: [
          {
            name: dataVolume,
            mountPath: mountPath,
          },
          {
            name: "aws-secret",
            mountPath: "/root/.aws/credentials",
          },
        ],
      },
      sidecars: sidecars,
    },  // buildTemplate

    // Workflow to run the e2e test.
    benchmark:: {
      apiVersion: "argoproj.io/v1alpha1",
      kind: "Workflow",
      metadata: {
        name: params.name,
        namespace: params.namespace,
      },
      spec: {
        entrypoint: "benchmark",
        volumes: [
          {
            name: dataVolume,
            persistentVolumeClaim: {
              claimName: nfsVolumeClaim,
            },
          },
          {
            name: "aws-secret",
            secret: {
              secretName: "aws-secret"
            },
          },
        ],  // volumes
        // onExit specifies the template that should always run when the workflow completes.
        onExit: "exit-handler",
        templates: [
          {
            name: "benchmark",
            steps: [
              [
                {
                  name: "checkout",
                  template: "checkout",
                },
              ],
              [
                {
                  name: "create-cluster",
                  template: "create-cluster",
                },
              ],
              [
                {
                  name: "install-addon",
                  template: "install-addon",
                },
              ],
              [
                {
                  name: "run-benchmark-job",
                  template: "run-benchmark-job",
                },
              ],
            ],
          },
          {
            name: "exit-handler",
            steps: [
              [
                {
                  name: "copy-results",
                  template: "copy-results",
                },
              ],
              [
                {
                  name: "teardown-cluster",
                  template: "teardown-cluster",
                },
              ],
              [
                {
                  name: "delete-test-dir",
                  template: "delete-test-dir",
                },
              ],
            ],
          },
          $.new(_env, _params).buildTemplate(
            "checkout",
            ["sh", "/usr/local/bin/download_source.sh", benchmarkSrcRootDir],
          ),  // checkout

          // $.new(_env, _params).buildTemplate("create-cluster", [
          //   "sh", srcDir + "/src/benchmark/test/fake_create.sh",
          // ], envVars=aws_credential_env
          // ),  // create cluster

          $.new(_env, _params).buildTemplate("create-cluster", [
            "python",
            "-m", 
            "benchmark.test.create_cluster",
            "--region=" + params.region,
            "--az=" + params.az,
            placementGroup,
            "--ami=" + params.ami,
            "--cluster_version=" + params.clusterVersion,
            "--instance_type=" + params.instanceType,
            "--node_count=" + "1",
          ], envVars=aws_credential_env
          ),  // create cluster

          $.new(_env, _params).buildTemplate("install-addon", [
            "python",
            "-m",
            "benchmark.test.install_addon",
            "--base_dir=" + benchmarkDir,
            "--namespace=" + params.namespace,
          ], envVars=github_token_env + aws_credential_env
          ),  // install addon

          $.new(_env, _params).buildTemplate("run-benchmark-job", [
            "python",
            "-m",
            "benchmark.test.run_benchmark_job",
            "--base_dir=" + benchmarkDir,
            "--namespace=" + params.namespace,
            "--experiment_name=" + "hehe",
            "--training_job_config=" + "mpi/mpi-job-dummy.yaml"
          ], envVars=github_token_env + aws_credential_env,
          ),  // run kubebench job

          $.new(_env, _params).buildTemplate("copy-results", [
            "sh", srcDir + "/src/benchmark/test/copy_results.sh",
          ]),  // copy-results

          $.new(_env, _params).buildTemplate("teardown-cluster", [
            "python",
            "-m",
            "benchmark.test.delete_cluster",
          ], envVars=aws_credential_env,
          ),  // teardown cluster

          // $.new(_env, _params).buildTemplate("copy-results", [
          //   "python",
          //   "-m",
          //   "benchmark.testing.copy-results",
          //   "--output_dir=" + benchmarkOutputDir,
          //   "--bucket=" + params.bucket,
          // ]),  // copy-results

          $.new(_env, _params).buildTemplate("delete-test-dir", [
            "bash",
            "-c",
            "rm -rf " + benchmarkDir,
          ]),  // delete test dir
        ],  // templates
      },
    },  // benchmark
  },  // parts
}