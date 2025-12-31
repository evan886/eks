#!/bin/bash
set -e

DOMAIN="dash.linuxsa.org"

echo "🚀 部署 Dashboard 到自定义域名: $DOMAIN"
echo ""

# 1. 部署 Dashboard
echo "📊 1. 部署 Kubernetes Dashboard..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# 2. 创建管理员用户
echo "👤 2. 创建管理员用户..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

# 3. 等待 Dashboard 就绪
echo "⏳ 3. 等待 Dashboard 启动..."
kubectl wait --for=condition=ready pod -l k8s-app=kubernetes-dashboard -n kubernetes-dashboard --timeout=120s

# 4. 创建 ALB Ingress（HTTP 版本）
echo "🌐 4. 创建 ALB Ingress..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dashboard-ingress
  namespace: kubernetes-dashboard
  annotations:
    # ALB 配置
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    # 如果需要 HTTPS，取消下面的注释并配置证书
    # alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    # alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-east-1:YOUR_ACCOUNT:certificate/YOUR_CERT_ID
    # alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  ingressClassName: alb
  rules:
  - host: $DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
EOF

# 5. 等待 ALB 创建
echo "⏳ 5. 等待 ALB 创建（大约需要 2-3 分钟）..."
sleep 15

ALB_URL=""
for i in {1..30}; do
  ALB_URL=$(kubectl get ingress dashboard-ingress -n kubernetes-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ ! -z "$ALB_URL" ]; then
    break
  fi
  echo "  等待中... ($i/30)"
  sleep 10
done

echo ""
echo "✅ 部署完成！"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 下一步操作"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ ! -z "$ALB_URL" ]; then
  echo "🔗 ALB 地址: $ALB_URL"
  echo ""
  echo "📝 DNS 配置："
  echo "   请在你的 DNS 服务商（域名管理面板）添加 CNAME 记录："
  echo ""
  echo "   类型: CNAME"
  echo "   主机记录: dash"
  echo "   记录值: $ALB_URL"
  echo "   TTL: 600"
  echo ""
  echo "   完整记录："
  echo "   dash.linuxsa.org  →  $ALB_URL"
  echo ""
  echo "⏰ DNS 生效时间："
  echo "   - 通常需要 5-10 分钟"
  echo "   - 最长可能需要 24 小时"
  echo ""
  echo "🔍 验证 DNS 是否生效："
  echo "   dig dash.linuxsa.org"
  echo "   nslookup dash.linuxsa.org"
  echo ""
  echo "🌐 DNS 生效后访问："
  echo "   http://dash.linuxsa.org"
else
  echo "❌ 无法获取 ALB 地址，请稍后检查："
  echo "   kubectl get ingress dashboard-ingress -n kubernetes-dashboard"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔑 登录 Token"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || echo "")
if [ ! -z "$TOKEN" ]; then
  echo "$TOKEN"
  echo ""
  echo "💾 请保存此 Token 用于登录"
else
  echo "稍后运行此命令获取 Token："
  echo "kubectl -n kubernetes-dashboard create token admin-user"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 提示："
echo "  1. 先配置 DNS CNAME 记录"
echo "  2. 等待 DNS 生效（5-10 分钟）"
echo "  3. 访问 http://dash.linuxsa.org"
echo "  4. 使用上面的 Token 登录"
echo ""
echo "🔒 如需 HTTPS，请继续执行后续步骤（申请 SSL 证书）"
