#!/bin/bash
set -e

echo "🔧 修复 and install AWS Load Balancer Controller"
echo ""

# 配置变量
CLUSTER_NAME="learning-eks"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "📋 配置信息:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $REGION"
echo "  Account: $AWS_ACCOUNT_ID"
echo ""

# 1. 卸载旧的部署
echo "🗑️  1. 清理旧的部署..."
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || echo "  没有找到旧的安装"
kubectl delete serviceaccount aws-load-balancer-controller -n kube-system 2>/dev/null || echo "  ServiceAccount 不存在"
echo ""

# 2. 下载 IAM Policy
echo "📥 2. 下载 IAM Policy..."
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

# 3. 创建或更新 IAM Policy
echo "📝 3. 创建 IAM Policy..."
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

if aws iam get-policy --policy-arn $POLICY_ARN &>/dev/null; then
  echo "  ✅ Policy 已存在"
  # 更新 policy
  POLICY_VERSION=$(aws iam create-policy-version \
    --policy-arn $POLICY_ARN \
    --policy-document file://iam_policy.json \
    --set-as-default \
    --query 'PolicyVersion.VersionId' \
    --output text 2>/dev/null || echo "")
  if [ ! -z "$POLICY_VERSION" ]; then
    echo "  ✅ Policy 已更新到版本: $POLICY_VERSION"
  fi
else
  aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
  echo "  ✅ Policy 创建完成"
fi
echo ""

# 4. 获取 OIDC Provider
echo "🔐 4. 配置 OIDC Provider..."
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo "  OIDC Provider: $OIDC_PROVIDER"

# 检查 OIDC Provider 是否存在
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn $OIDC_PROVIDER_ARN &>/dev/null; then
  echo "  ⚠️  OIDC Provider 不存在，正在创建..."
  eksctl utils associate-iam-oidc-provider --cluster=$CLUSTER_NAME --region=$REGION --approve
  echo "  ✅ OIDC Provider 创建完成"
else
  echo "  ✅ OIDC Provider 已存在"
fi
echo ""

# 5. 创建 IAM Role 和 Trust Policy
echo "🎭 5. 创建 IAM Role..."
ROLE_NAME="AmazonEKSLoadBalancerControllerRole"

cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }
  ]
}
EOF

if aws iam get-role --role-name $ROLE_NAME &>/dev/null; then
  echo "  ✅ Role 已存在，更新 Trust Policy..."
  aws iam update-assume-role-policy --role-name $ROLE_NAME --policy-document file://trust-policy.json
else
  echo "  创建新 Role..."
  aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json
  echo "  ✅ Role 创建完成"
fi

# 附加 Policy 到 Role
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
echo "  ✅ Policy 已附加到 Role"
echo ""

# 6. 创建 Kubernetes ServiceAccount
echo "👤 6. 创建 ServiceAccount..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}
EOF
echo "  ✅ ServiceAccount 创建完成"
echo ""

# 7. 安装 cert-manager（ALB Controller 依赖）
echo "📜 7. 安装 cert-manager..."
if ! kubectl get namespace cert-manager &>/dev/null; then
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
  echo "  等待 cert-manager 就绪..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
  echo "  ✅ cert-manager 安装完成"
else
  echo "  ✅ cert-manager 已存在"
fi
echo ""

# 8. 获取 VPC ID
echo "🌐 8. 获取 VPC ID..."
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)
echo "  VPC ID: $VPC_ID"
echo ""

# 9. 添加 Helm 仓库
echo "📦 9. 配置 Helm 仓库..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
echo ""

# 10. 安装 AWS Load Balancer Controller
echo "🚀 10. 安装 AWS Load Balancer Controller..."
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION \
  --set vpcId=$VPC_ID
echo ""

# 11. 等待部署就绪
echo "⏳ 11. 等待 Controller 就绪（最多 3 分钟）..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system --timeout=180s

echo ""
echo "✅ AWS Load Balancer Controller 安装成功！"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 验证结果"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Deployment 状态:"
kubectl get deployment -n kube-system aws-load-balancer-controller
echo ""

echo "Pod 状态:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
echo ""

echo "查看日志:"
echo "kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 清理临时文件
rm -f iam_policy.json trust-policy.json
