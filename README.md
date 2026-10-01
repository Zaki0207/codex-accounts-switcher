# Codex Accounts

一个适用于 macOS 的 Codex 多账号菜单栏工具。它可以保存各账号的桌面授权、切换主 Codex 登录，并查看常规额度和重置卡。切换时共用默认 `~/.codex` 目录，因此本地项目和聊天记录仍由同一个 Codex 实例使用。

## 要求

- Apple Silicon Mac、macOS 14 或更新版本
- Codex 桌面应用安装在 `/Applications/ChatGPT.app`
- 主 Codex 的有效配置明确设置 `cli_auth_credentials_store = "file"`

## 构建与安装

```sh
cd CodexAccounts-source
./test.sh
./build.sh
```

`build.sh` 会生成项目根目录的 `CodexAccounts.app`，并安装到 `/Applications/Codex Accounts.app`。若安装版正在运行，构建成功后会更新并重新打开它。启动后从菜单栏的双人图标进入；该程序没有 Dock 图标。

账号数据库、授权文件和取码网址均保存在本机用户资料或钥匙串中，不属于本仓库。具体使用说明、存储位置和限制见 [详细说明](CodexAccounts-source/README.md)。
