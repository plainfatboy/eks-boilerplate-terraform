provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {}

locals {
  cluster_name = "man-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "education-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.24"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }

    # two = {
    #   name = "node-group-2"

    #   instance_types = ["t3.small"]

    #   min_size     = 1
    #   max_size     = 2
    #   desired_size = 1
    # }
  }
}


# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.21.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_eks_addon" "ebs-csi" {
  depends_on               = [module.eks]
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.18.0-eksbuild.1"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

resource "helm_release" "ingress-nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.7.0"
  namespace        = "ingress-nginx"
  cleanup_on_fail  = "true"
  create_namespace = "true"
}

resource "null_resource" "aws_load_balancer_controller_iam_policy_downloader" {
  provisioner "local-exec" {
    command = "curl https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.7/docs/install/iam_policy.json > aws_load_balancer_controller_iam_policy.json"
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

resource "aws_iam_policy" "aws_load_balancer_controller_iam_policy" {
  depends_on = [null_resource.aws_load_balancer_controller_iam_policy_downloader]
  name       = "AWSLoadBalancerControllerIAMPolicy"
  policy     = file("./aws_load_balancer_controller_iam_policy.json")
}

locals {
  depends_on = [module.eks]

  splitted_cluster_arn = split(":", module.eks.cluster_arn)

  aws_root_account_id = local.splitted_cluster_arn[4]
}

# eksctl create iamserviceaccount \
#   --cluster=my-cluster \
#   --namespace=kube-system \
#   --name=aws-load-balancer-controller \
#   --role-name AmazonEKSLoadBalancerControllerRole \
#   --attach-policy-arn=arn:aws:iam::111122223333:policy/AWSLoadBalancerControllerIAMPolicy \
#   --approve

resource "null_resource" "obtain_eks_oidc_id" {
  provisioner "local-exec" {
    command = "aws eks describe-cluster --name ${module.eks.cluster_name} --query \"cluster.identity.oidc.issuer\" --output text | cut -d '/' -f 5 > oidc_id"
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

resource "null_resource" "binded_oidc_id" {
  provisioner "local-exec" {
    command = "aws iam list-open-id-connect-providers | grep $(cat oidc_id) | cut -d \"/\" -f4 | sed \"s/\\\"//\" > binded_oidc_id"
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

resource "null_resource" "confirm_binded_oidc_id" {
  depends_on = [null_resource.obtain_eks_oidc_id, null_resource.binded_oidc_id]
  provisioner "local-exec" {
    command = "if diff oidc_id binded_oidc_id; then exit 0; else echo \"oidc does not match\"; exit 1; fi"
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

# data "template_file" "load-balancer-role-trust-policy" {
#   depends_on = [null_resource.confirm_binded_oidc_id]
#   template = "${file("${path.module}/templates/load-balancer-role-trust-policy.json.tpl")}"
#   vars = {
#     aws_root_account_id = local.aws_root_account_id
#     region_code         = var.region_code
#     oidc_id             = file("./oidc_id")
#   }
# }

resource "aws_iam_role" "aws_eks_load_balancer_controller" {
  depends_on = [null_resource.confirm_binded_oidc_id]

  name = "AmazonEKSLoadBalancerControllerRole"

  assume_role_policy = trimspace(
    replace(
      replace(
        templatefile(
          "${path.module}/templates/load-balancer-role-trust-policy.json.tftpl",
          {
            aws_root_account_id = local.aws_root_account_id
            region_code         = var.region
            oidc_id             = file("./oidc_id")
          }
        ), "\n", ""
      ), " ", ""
    )
  )
}

resource "aws_iam_role_policy_attachment" "eks_lb_controller_attach_with_aws_lb_controller_iam_policy" {
  role       = aws_iam_role.aws_eks_load_balancer_controller.name
  policy_arn = "arn:aws:iam::${local.aws_root_account_id}:policy/AWSLoadBalancerControllerIAMPolicy"
}

resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" : "arn:aws:iam::${local.aws_root_account_id}:role/AmazonEKSLoadBalancerControllerRole"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  depends_on = [ kubernetes_service_account.aws_load_balancer_controller ]
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.5.4"
  namespace        = "kube-system"
  cleanup_on_fail  = "true"

  set {
    name = "clusterName"
    value = local.cluster_name
  }

  set {
    name = "image.tag"
    value = "v2.5.3"
  }

  set {
    name = "serviceAccount.create"
    value = "false"
  }

  set {
    name = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
}