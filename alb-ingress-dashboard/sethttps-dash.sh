#!/bin/bash
set -e

DOMAIN="dash.linuxsa.org"
REGION="us-east-1"

echo "🔒 配置 HTTPS 访问"
echo ""

echo "📋 步骤概览："
echo "  1. 在 AWS ACM 申请 SSL 证书"
echo "  2. 验证域名所有权"
echo "  3. 更新 Ingress 配置使用 HTTPS"
echo ""

# 1. 申请证书
echo "📜 1. 在 AWS ACM 申请证书..."
echo ""
echo "方式一：使用 AWS CLI 申请（需要邮箱验证）"
echo "----------------------------------------"

CERT_ARN=$(aws acm request-certificate \
  --domain-name $DOMAIN \
  --validation-method DNS \
  --region $REGION \
  --query 'CertificateArn' \
  --output text 2>/dev/null || echo "")

if [ ! -z "$CERT_ARN" ]; then
  echo "✅ 证书申请已提交"
  echo "   证书 ARN: $CERT_ARN"
  echo ""
  
  # 获取验证信息
  echo "📝 2. DNS 验证记录（请添加到你的 DNS）："
  echo ""
  
  sleep 5  # 等待 AWS 生成验证记录
  
  aws acm describe-certificate \
    --certificate-arn $CERT_ARN \
    --region $REGION \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
    --output table
  
  echo ""
  echo "⚠️  重要：你需要在 DNS 中添加上面的 CNAME 记录来验证域名所有权"
  echo ""
  echo "等待证书验证（这可能需要几分钟到几小时）..."
  echo "检查证书状态："
  echo "aws acm describe-certificate --certificate-arn $CERT_ARN --region $REGION --query 'Certificate.Status'"
  echo ""
  
  # 保存证书 ARN
  echo $CERT_ARN > .cert_arn
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 验证完成后，运行以下命令更新 Ingress："
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  cat <<EOF > update-ingress-https.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dashboard-ingress
  namespace: kubernetes-dashboard
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTPS
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: $CERT_ARN
    alb.ingress.kubernetes.io/ssl-redirect: '443'
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
  
  echo "kubectl apply -f update-ingress-https.yaml"
  echo ""
  echo "文件已保存到: update-ingress-https.yaml"
  
else
  echo "⚠️  自动申请失败，请手动在 AWS Console 申请"
  echo ""
  echo "方式二：在 AWS Console 手动申请（推荐）"
  echo "----------------------------------------"
  echo ""
  echo "1. 打开 AWS ACM Console:"
  echo "   https://console.aws.amazon.com/acm/home?region=$REGION"
  echo ""
  echo "2. 点击 '申请证书' → '申请公有证书'"
  echo ""
  echo "3. 输入域名: $DOMAIN"
  echo ""
  echo "4. 选择 'DNS 验证'"
  echo ""
  echo "5. 在你的 DNS 服务商添加 CNAME 验证记录"
  echo ""
  echo "6. 等待证书状态变为 '已颁发'"
  echo ""
  echo "7. 复制证书 ARN（类似: arn:aws:acm:ap-east-1:123456789:certificate/xxx）"
  echo ""
  echo "8. 运行以下命令更新 Ingress:"
  echo ""
  echo "   CERT_ARN='你的证书ARN'"
  echo "   kubectl patch ingress dashboard-ingress -n kubernetes-dashboard --type='json' -p='["
  echo "     {\"op\": \"add\", \"path\": \"/metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn\", \"value\": \"'\$CERT_ARN'\"},"
  echo "     {\"op\": \"replace\", \"path\": \"/metadata/annotations/alb.ingress.kubernetes.io~1listen-ports\", \"value\": \"[{\\\"HTTP\\\": 80}, {\\\"HTTPS\\\": 443}]\"},"
  echo "     {\"op\": \"add\", \"path\": \"/metadata/annotations/alb.ingress.kubernetes.io~1ssl-redirect\", \"value\": \"443\"}"
  echo "   ]'"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📌 完整流程总结"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. 配置 DNS CNAME (ALB):"
echo "   dash.linuxsa.org → ALB地址"
echo ""
echo "2. 添加 DNS CNAME (证书验证):"
echo "   _xxx.dash.linuxsa.org → _yyy.acm-validations.aws"
echo ""
echo "3. 等待验证完成（5-30分钟）"
echo ""
echo "4. 更新 Ingress 启用 HTTPS"
echo ""
echo "5. 访问 https://dash.linuxsa.org"
