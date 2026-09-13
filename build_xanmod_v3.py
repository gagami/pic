from pathlib import Path
import re

root = Path(__file__).resolve().parent
s = (root / 'vps_fixed_xanmod.original.sh').read_text(encoding='utf-8-sig')
s = s.replace('SCRIPT_VERSION="2.1"', 'SCRIPT_VERSION="3.0"')
s = re.sub(r'\(\((\w+)\+\+\)\)', lambda m: f'{m[1]}=$(({m[1]} + 1))', s)
s = s.replace('retry_count=$((retry_count + 1))\n            local exit_code=$?', 'local exit_code=$?\n            retry_count=$((retry_count + 1))')
s = s.replace('local apt_processes=$(pgrep -f "apt-get|apt|dpkg" | wc -l)', 'local apt_processes\n    apt_processes=$(pgrep -x "apt-get|apt|dpkg" | wc -l) || true')
s = s.replace('systemctl restart sshd || handle_error $? "SSH服务重启失败"', 'sshd -t || handle_error $? "SSH配置校验失败"\nsystemctl restart ssh || handle_error $? "SSH服务重启失败"')
s = s.replace('apt-get autoremove -yqq', '# 保留旧内核供回退，不执行全局 autoremove')
s = s.replace('select KERNEL_TYPE in "main" "edge"; do', 'select KERNEL_TYPE in "lts" "main" "edge"; do')
s = s.replace('^(main|edge)$', '^(lts|main|edge)$').replace('请输入 1 或 2.', '请输入 1、2 或 3.')
start = s.index('log "PROGRESS" "检测系统并安装 XanMod 内核..."')
end = s.index('# 网络优化', start)
end = s.rfind('# ==============================', start, end)
s = s[:start] + 'xanmod_install\n\n' + s[end:]
pos = s.index('# 交互部分')
pos = s.rfind('# ==============================', 0, pos)
s = s[:pos] + (root / 'xanmod_v3_block.tmp').read_text(encoding='utf-8') + '\n\n' + s[pos:]
(root / 'vps_fixed_xanmod_v3.sh').write_text(s, encoding='utf-8', newline='\n')
