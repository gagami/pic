#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nginx配置检查和HTTP 400错误诊断工具
"""

import subprocess
import re
import sys

def check_nginx_config():
    """检查nginx配置"""
    print("Nginx配置检查")
    print("=" * 40)

    # 检查nginx配置语法
    try:
        result = subprocess.run(['nginx', '-t'], capture_output=True, text=True)
        if result.returncode == 0:
            print("✓ Nginx配置语法正确")
        else:
            print("✗ Nginx配置语法错误:")
            print(result.stderr)
            return False
    except FileNotFoundError:
        print("✗ Nginx未安装或不在PATH中")
        return False

    return True

def analyze_nginx_config():
    """分析nginx配置文件"""
    print("\n分析Nginx配置")
    print("=" * 40)

    config_files = [
        '/etc/nginx/nginx.conf',
        '/etc/nginx/sites-available/default',
        '/etc/nginx/conf.d/default.conf',
        '/usr/local/nginx/conf/nginx.conf'
    ]

    relevant_configs = []

    for config_file in config_files:
        try:
            with open(config_file, 'r') as f:
                content = f.read()
                if 'api_mcp' in content or 'dav' in content.lower():
                    relevant_configs.append((config_file, content))
                    print(f"✓ 找到相关配置: {config_file}")
        except FileNotFoundError:
            continue
        except Exception as e:
            print(f"✗ 读取配置文件失败 {config_file}: {e}")

    if not relevant_configs:
        print("✗ 未找到包含api_mcp或dav的配置")
        return False

    # 分析配置内容
    for config_file, content in relevant_configs:
        print(f"\n--- 分析配置文件: {config_file} ---")

        # 检查关键配置项
        checks = [
            (r'client_max_body_size\s+(\S+);', 'client_max_body_size'),
            (r'dav_methods\s+(.+);', 'dav_methods'),
            (r'dav_access\s+(.+);', 'dav_access'),
            (r'create_full_put_path\s+(.+);', 'create_full_put_path'),
            (r'auth_basic\s+"?([^"]+)"?;', 'auth_basic'),
            (r'auth_basic_user_file\s+(.+);', 'auth_basic_user_file'),
            (r'location\s+/api_mcp\s*{', 'api_mcp location'),
        ]

        for pattern, name in checks:
            matches = re.findall(pattern, content, re.IGNORECASE)
            if matches:
                print(f"  ✓ {name}: {matches[0]}")
            else:
                print(f"  ✗ {name}: 未找到")

        # 检查错误日志配置
        error_log_match = re.search(r'error_log\s+(.+);', content)
        if error_log_match:
            print(f"  ✓ 错误日志: {error_log_match.group(1)}")
        else:
            print(f"  ✗ 错误日志: 未找到")

    return True

def check_nginx_error_log():
    """检查nginx错误日志"""
    print("\n检查Nginx错误日志")
    print("=" * 40)

    log_files = [
        '/var/log/nginx/error.log',
        '/usr/local/nginx/logs/error.log',
        '/var/log/nginx/error.log.1'
    ]

    for log_file in log_files:
        try:
            # 检查文件是否存在
            result = subprocess.run(['tail', '-20', log_file],
                                  capture_output=True, text=True)
            if result.returncode == 0:
                print(f"--- {log_file} (最近20行) ---")
                lines = result.stdout.strip().split('\n')

                # 查找400错误相关日志
                error_lines = [line for line in lines if '400' in line or 'api_mcp' in line]

                if error_lines:
                    print("  发现相关错误:")
                    for line in error_lines:
                        print(f"    {line}")
                else:
                    print("  未发现400错误相关日志")

                break
        except FileNotFoundError:
            continue
        except Exception as e:
            print(f"读取日志文件失败 {log_file}: {e}")

def suggest_nginx_config():
    """建议nginx配置"""
    print("\n建议的Nginx配置")
    print("=" * 40)

    recommended_config = '''
server {
    listen 80;
    server_name 154.29.150.2;

    # API_MCP目录配置
    location /api_mcp/ {
        alias /var/www/api_mcp/;
        index index.html;

        # WebDAV配置
        dav_methods PUT DELETE MKCOL COPY MOVE;
        dav_ext_methods PROPFIND OPTIONS;
        dav_access user:rw group:rw all:rw;
        create_full_put_path on;

        # 基本认证
        auth_basic "API MCP Restricted Area";
        auth_basic_user_file /etc/nginx/.htpasswd;

        # 文件大小限制
        client_max_body_size 100M;
        client_body_buffer_size 128k;

        # 安全头
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options DENY;

        # 目录浏览
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }

    # 错误和访问日志
    access_log /var/log/nginx/api_mcp_access.log;
    error_log /var/log/nginx/api_mcp_error.log;
}
'''

    print("推荐的api_mcp配置:")
    print(recommended_config)

def check_system_resources():
    """检查系统资源"""
    print("\n系统资源检查")
    print("=" * 40)

    # 检查磁盘空间
    try:
        result = subprocess.run(['df', '-h', '/var/www'],
                              capture_output=True, text=True)
        if result.returncode == 0:
            print("✓ 磁盘空间:")
            print(f"  {result.stdout.strip()}")
    except:
        pass

    # 检查nginx进程
    try:
        result = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
        nginx_processes = [line for line in result.stdout.split('\n')
                          if 'nginx' in line and not 'grep' in line]

        if nginx_processes:
            print(f"✓ Nginx进程数: {len(nginx_processes)}")
        else:
            print("✗ 未找到Nginx进程")
    except:
        pass

    # 检查端口监听
    try:
        result = subprocess.run(['netstat', '-tlnp'], capture_output=True, text=True)
        if '80' in result.stdout:
            print("✓ 端口80正在监听")
        else:
            print("✗ 端口80未监听")
    except:
        pass

def main():
    """主函数"""
    print("Nginx HTTP 400错误诊断工具")
    print("=" * 50)

    # 检查nginx配置
    if not check_nginx_config():
        return

    # 分析配置
    analyze_nginx_config()

    # 检查错误日志
    check_nginx_error_log()

    # 检查系统资源
    check_system_resources()

    # 提供建议
    suggest_nginx_config()

    print("\n" + "=" * 50)
    print("诊断建议:")
    print("1. 检查client_max_body_size是否足够大 (建议100M)")
    print("2. 确认WebDAV模块已正确加载")
    print("3. 验证auth_basic_user_file文件存在且格式正确")
    print("4. 检查/var/www/api_mcp目录权限")
    print("5. 查看nginx错误日志获取详细信息")
    print("6. 使用改进版v2ray脚本测试上传")

if __name__ == "__main__":
    main()