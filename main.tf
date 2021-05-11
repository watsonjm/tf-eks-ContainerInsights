
# IAM policy to allow container insights to write to CloudWatch
data "aws_iam_policy" "container_insights" {
  arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "container_insights" {
  role       = module.eks.worker_iam_role_name
  policy_arn = data.aws_iam_policy.container_insights.arn
}

data "aws_iam_policy" "ssm_managed_instance" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = module.eks.worker_iam_role_name
  policy_arn = data.aws_iam_policy.ssm_managed_instance.arn
}

# create amazon-cloudwatch namespace
# ref https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-metrics.html
# from https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml
resource "kubernetes_namespace" "cloudwatch_ns" {
  depends_on = [module.eks]
  metadata {
    labels = {
      name = "amazon-cloudwatch"
    }
    name = "amazon-cloudwatch"
  }
}

# create cwagent service account and role binding
# from https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-serviceaccount.yaml
resource "kubernetes_service_account" "cloudwatch_agent" {
  depends_on = [kubernetes_namespace.cloudwatch_ns]
  metadata {
    name      = "cloudwatch-agent"
    namespace = "amazon-cloudwatch"
  }
}

resource "kubernetes_cluster_role" "cloudwatch_agent" {
  depends_on = [module.eks]
  metadata {
    name = "cloudwatch-agent-role"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "nodes", "endpoints"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes/proxy"]
    verbs      = ["get"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes/proxy"]
    verbs      = ["get"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes/stats", "configmaps", "events"]
    verbs      = ["create"]
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["cwagent-clusterleader"]
    verbs          = ["get", "update"]
  }
}

resource "kubernetes_cluster_role_binding" "cloudwatch_agent" {
  depends_on = [kubernetes_cluster_role.cloudwatch_agent, kubernetes_service_account.cloudwatch_agent]
  metadata {
    name = "cloudwatch-agent-role-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cloudwatch-agent-role"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "cloudwatch-agent"
    namespace = "amazon-cloudwatch"
  }
}

# create configmap for cloudwatch agent
resource "kubernetes_config_map" "cloudwatch_agent" {
  depends_on = [kubernetes_namespace.cloudwatch_ns]
  metadata {
    name      = "cwagentconfig"
    namespace = "amazon-cloudwatch"
  }
  data = {
    "cwagentconfig.json" = <<JSON
{
  "logs": {
    "metrics_collected": {
      "kubernetes": {
        "cluster_name": "${module.eks.cluster_id}",
        "metrics_collection_interval": 60
      }
    },
    "force_flush_interval": 5
  }
}
JSON
  }
}

# deploy cwagent as daemonset
# from https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cwagent/cwagent-daemonset.yaml
# generated with k2tf https://github.com/sl1pm4t/k2tf
resource "kubernetes_daemonset" "cloudwatch_agent" {
  depends_on = [kubernetes_cluster_role_binding.cloudwatch_agent]
  metadata {
    name      = "cloudwatch-agent"
    namespace = "amazon-cloudwatch"
  }

  spec {
    selector {
      match_labels = {
        name = "cloudwatch-agent"
      }
    }

    template {
      metadata {
        labels = {
          name = "cloudwatch-agent"
        }
      }

      spec {
        volume {
          name = "cwagentconfig"

          config_map {
            name = "cwagentconfig"
          }
        }

        volume {
          name = "rootfs"

          host_path {
            path = "/"
          }
        }

        volume {
          name = "dockersock"

          host_path {
            path = "/var/run/docker.sock"
          }
        }

        volume {
          name = "varlibdocker"

          host_path {
            path = "/var/lib/docker"
          }
        }

        volume {
          name = "sys"

          host_path {
            path = "/sys"
          }
        }

        volume {
          name = "devdisk"

          host_path {
            path = "/dev/disk/"
          }
        }

        container {
          name  = "cloudwatch-agent"
          image = "amazon/cloudwatch-agent:1.247347.5b250583"

          env {
            name = "HOST_IP"

            value_from {
              field_ref {
                field_path = "status.hostIP"
              }
            }
          }

          env {
            name = "HOST_NAME"

            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          env {
            name = "K8S_NAMESPACE"

            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }

          env {
            name  = "CI_VERSION"
            value = "k8s/1.3.5"
          }

          resources {
            limits = {
              cpu    = "200m"
              memory = "200Mi"
            }

            requests = {
              cpu    = "200m"
              memory = "200Mi"
            }
          }

          volume_mount {
            name       = "cwagentconfig"
            mount_path = "/etc/cwagentconfig"
          }

          volume_mount {
            name       = "rootfs"
            read_only  = true
            mount_path = "/rootfs"
          }

          volume_mount {
            name       = "dockersock"
            read_only  = true
            mount_path = "/var/run/docker.sock"
          }

          volume_mount {
            name       = "varlibdocker"
            read_only  = true
            mount_path = "/var/lib/docker"
          }

          volume_mount {
            name       = "sys"
            read_only  = true
            mount_path = "/sys"
          }

          volume_mount {
            name       = "devdisk"
            read_only  = true
            mount_path = "/dev/disk"
          }
        }

        termination_grace_period_seconds = 60
        service_account_name             = "cloudwatch-agent"
      }
    }
  }
}