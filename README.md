# Linux 工具箱 🚀

一个简单好用的Linux系统管理工具，一键解决常见系统管理问题。

## 快速开始

### 一键运行（推荐）
```bash
curl -Ls https://raw.githubusercontent.com/GamblerIX/linux-toolbox/main/toolv1.sh | bash
```

### 下载运行
```bash
wget https://raw.githubusercontent.com/GamblerIX/linux-toolbox/main/toolv1.sh
chmod +x toolv1.sh
./toolv1.sh
```

## 支持系统
- Ubuntu 16.04+
- Debian 9+ 
- CentOS 7/8

## 主要功能

### 🧹 系统管理
- **系统清理**：清理垃圾文件，释放磁盘空间
- **用户管理**：创建/删除用户，修改密码
- **内核管理**：查看/删除旧内核

### 🌐 网络工具
- **网速测试**：测试网络速度
- **SSH日志**：查看登录记录
- **防火墙管理**：开放/关闭端口
- **BBR加速**：一键开启网络加速
- **端口扫描**：查看占用的端口

### 📦 换源加速
支持一键切换到国内镜像源：
- 阿里云源（推荐）
- 腾讯云源
- 中科大源
- 清华源

### 🎛️ 面板安装
一键安装Web管理面板：
- 宝塔面板（推荐新手）
- 1Panel（Docker用户）
- aapanel（国际版）

## 使用说明

1. 运行脚本后会显示主菜单
2. 输入对应数字选择功能
3. 按照提示操作即可
4. 大部分操作需要root权限（脚本会自动获取）

## 安全提醒

- 脚本会自动备份重要配置文件
- 操作前会有确认提示
- 建议在测试环境先试用

## 问题反馈

如有问题请到GitHub提交：https://github.com/GamblerIX/linux-toolbox/issues
