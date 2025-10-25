#!/bin/bash
# Ubuntu Nginx配置和SSL证书申请脚本
# 用于ai.996111.xyz域名 - 隐藏目录访问

set -e

DOMAIN="ai.996111.xyz"
WEB_ROOT="/var/www/api_mcp"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
EMAIL="admin@996111.xyz"  # 请替换为您的邮箱

echo "=========================================="
echo "Ubuntu Nginx配置和SSL证书设置脚本"
echo "域名: $DOMAIN"
echo "文件上传限制: 100MB"
echo "模式: 隐藏目录访问"
echo "=========================================="

# 检查是否以root权限运行
if [[ $EUID -ne 0 ]]; then
   echo "此脚本需要root权限运行"
   echo "请使用: sudo bash $0"
   exit 1
fi

# 清理之前的配置
echo "清理之前的配置..."
# 停止nginx服务
systemctl stop nginx 2>/dev/null || true

# 删除网站目录
rm -rf /var/www/downdownupup
rm -rf /var/www/api_mcp

# 删除nginx配置
rm -f /etc/nginx/sites-enabled/$DOMAIN
rm -f /etc/nginx/sites-available/$DOMAIN
rm -f /etc/nginx/sites-enabled/default

# 删除SSL证书（可选）
echo "是否删除之前的SSL证书？(y/n)"
read -r DELETE_CERTS
if [[ $DELETE_CERTS =~ ^[Yy]$ ]]; then
    certbot delete --cert-name $DOMAIN 2>/dev/null || true
    echo "SSL证书已删除"
fi

# 删除日志文件
rm -f /var/www/logs/${DOMAIN}_access.log
rm -f /var/www/logs/${DOMAIN}_error.log

# 删除nginx临时文件
rm -rf /var/nginx/client_temp 2>/dev/null || true

echo "清理完成！"

# 更新系统包
echo "更新系统包..."
apt update && apt upgrade -y

# 安装必要的软件包
echo "安装Nginx、Certbot和认证工具..."
apt update
apt install -y nginx certbot python3-certbot-nginx nginx-extras apache2-utils

# 创建网站目录
echo "创建网站目录..."
mkdir -p $WEB_ROOT
mkdir -p /var/www/logs
chown -R www-data:www-data $WEB_ROOT
chmod -R 755 $WEB_ROOT

# 创建认证密码文件
echo "创建认证密码文件..."
USERNAME="apiuser"
PASSWORD="api_mcp_2024_secure"
htpasswd -cb /etc/nginx/.htpasswd "$USERNAME" "$PASSWORD"

# 创建初始nginx配置（HTTP only，用于证书申请）
echo "创建初始Nginx配置..."
cat > $NGINX_CONF << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # 客户端上传文件大小限制：100MB
    client_max_body_size 100M;

    # 客户端请求超时设置
    client_body_timeout 300s;
    client_header_timeout 300s;

    # 根目录 - 返回404，不显示任何内容
    location / {
        return 404;
    }

    # 文件同步目录 - 密码保护的目录访问和文件上传
    location /api_mcp/ {
        alias $WEB_ROOT/;

        # HTTP基础认证
        auth_basic "API MCP Access";
        auth_basic_user_file /etc/nginx/.htpasswd;

        # 启用目录列表
        autoindex on;
        autoindex_exact_size on;
        autoindex_localtime on;
        autoindex_format html;

        # 启用WebDAV用于文件上传
        dav_methods PUT DELETE MKCOL COPY MOVE;
        dav_access group:rw all:rw;

        # 创建目录权限
        create_full_put_path on;

        # 文件上传大小限制：100MB
        client_max_body_size 100M;

        # 大文件上传超时设置
        client_body_timeout 600s;
        send_timeout 600s;

        # CORS设置
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range' always;

        # OPTIONS请求处理
        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        # 下载文件时设置下载头
        if (\$request_method = GET) {
            add_header Content-Disposition "attachment";
            expires 1d;
            add_header Cache-Control "public, immutable";
        }
    }

    # 禁止访问其他路径
    location ~ ^/(?!api_mcp/|health) {
        return 404;
    }

    # 健康检查
    location /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    # 禁止访问隐藏文件和配置文件
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # 日志
    access_log /var/www/logs/${DOMAIN}_access.log;
    error_log /var/www/logs/${DOMAIN}_error.log;
}
EOF

# 启用站点
echo "启用Nginx站点..."
ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# 测试nginx配置
echo "测试Nginx配置..."
nginx -t

# 重启nginx
echo "重启Nginx..."
systemctl restart nginx
systemctl enable nginx

# 申请SSL证书
echo "申请SSL证书..."
certbot --nginx -d $DOMAIN --email $EMAIL --agree-tos --no-eff-email --non-interactive

# 如果证书申请成功，更新配置为HTTPS
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "SSL证书申请成功，更新配置为HTTPS..."

    cat > $NGINX_CONF << EOF
# HTTP重定向到HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

# HTTPS服务器配置
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    # SSL证书配置
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # SSL安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 安全头设置
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # 客户端上传文件大小限制：100MB
    client_max_body_size 100M;

    # 客户端请求超时设置（支持大文件上传）
    client_body_timeout 600s;
    client_header_timeout 300s;

    # 根目录 - 返回404，不显示任何内容
    location / {
        return 404;
    }

    # 文件同步目录 - 密码保护的目录访问和文件上传
    location /api_mcp/ {
        alias $WEB_ROOT/;

        # HTTP基础认证
        auth_basic "API MCP Access";
        auth_basic_user_file /etc/nginx/.htpasswd;

        # 启用目录列表
        autoindex on;
        autoindex_exact_size on;
        autoindex_localtime on;
        autoindex_format html;

        # 启用WebDAV用于文件上传
        dav_methods PUT DELETE MKCOL COPY MOVE;
        dav_access group:rw all:rw;

        # 创建目录权限
        create_full_put_path on;

        # 文件大小限制：100MB
        client_max_body_size 100M;

        # 大文件上传超时设置
        client_body_timeout 600s;
        send_timeout 600s;

        # CORS设置
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range' always;

        # 处理OPTIONS预检请求
        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        # 下载文件时设置下载头
        if (\$request_method = GET) {
            add_header Content-Disposition "attachment";
            expires 1d;
            add_header Cache-Control "public, immutable";
        }
    }

    # 禁止访问其他所有路径
    location ~ ^/(?!api_mcp/|health) {
        return 404;
    }

    # 健康检查端点
    location /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    # 禁止访问隐藏文件、配置文件和目录列表
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # 禁止目录浏览
    autoindex off;

    # 日志配置
    access_log /var/www/logs/${DOMAIN}_access.log;
    error_log /var/www/logs/${DOMAIN}_error.log;
}
EOF

    # 创建nginx临时目录
    mkdir -p /var/nginx/client_temp
    chown -R www-data:www-data /var/nginx

    # 重新加载nginx配置
    nginx -t
    systemctl reload nginx

    echo "HTTPS配置完成！"
else
    echo "SSL证书申请失败，请检查域名DNS配置和邮箱地址"
fi

# 设置证书自动续期
echo "设置证书自动续期..."
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx") | crontab -

# 创建示例文件用于测试（仅程序可访问）
echo "创建测试文件..."
echo "This is a test file for api_mcp" > $WEB_ROOT/test.txt
echo '{"version": "1.0", "service": "api_mcp"}' > $WEB_ROOT/config.json

# 显示完成信息
echo "=========================================="
echo "配置完成！"
echo "=========================================="
echo "网站地址: https://$DOMAIN"
echo "直接访问域名: 返回404 (隐藏)"
echo "文件同步路径: https://$DOMAIN/api_mcp/ (需要认证)"
echo "健康检查: https://$DOMAIN/health (无需认证)"
echo ""
echo "🔐 认证信息："
echo "   用户名: $USERNAME"
echo "   密码: $PASSWORD"
echo ""
echo "安全配置:"
echo "- 根目录访问返回404"
echo "- /api_mcp/目录需要密码认证"
echo "- 启用目录列表功能"
echo "- 禁止访问隐藏文件"
echo "- 只允许访问 /api_mcp/ 和 /health"
echo ""
echo "文件上传配置:"
echo "- 最大文件大小: 100MB"
echo "- 上传超时: 600秒"
echo "- WebDAV和目录访问都需要认证"
echo ""
echo "程序测试命令:"
echo "curl https://$DOMAIN/health"
echo "curl -u $USERNAME:$PASSWORD https://$DOMAIN/api_mcp/test.txt"
echo "curl -X PUT -u $USERNAME:$PASSWORD --data-binary @file.dll https://$DOMAIN/api_mcp/file.dll"
echo ""
echo "浏览器访问测试:"
echo "https://$DOMAIN/ (应该返回404)"
echo "https://$DOMAIN/api_mcp/ (需要输入用户名和密码)"
echo ""
echo "证书文件位置:"
echo "证书: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "私钥: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "密码文件: /etc/nginx/.htpasswd"
echo ""
echo "日志文件:"
echo "访问日志: /var/www/logs/${DOMAIN}_access.log"
echo "错误日志: /var/www/logs/${DOMAIN}_error.log"
echo ""
echo "Nginx配置文件: $NGINX_CONF"
echo "=========================================="

# 测试配置
echo "测试网站配置..."
sleep 5

echo "测试根访问 (应该返回404):"
curl -s -w "Status: %{http_code}\n" https://$DOMAIN/ | head -1

echo "测试健康检查:"
curl -s https://$DOMAIN/health || echo "网站可能还在启动中，请稍等几分钟后测试"

echo "脚本执行完成！"
