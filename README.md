# sshyard-pass

读取 SSHYard 本地加密库，按主机取出密码 / 私钥 / 私钥口令。仅支持 macOS。

SSHYard 本身不提供「回看密码」的界面，密码只存在 `secrets.enc` 里。这个项目做的事就是：
用钥匙串里的主密钥把 `secrets.enc` 解开，再按主机把对应条目交给你。

## 组成

| 路径 | 作用 |
| --- | --- |
| `main.go` | 命令行工具，负责读钥匙串、解密、匹配主机 |
| `app/main.swift` | macOS 图形界面，列主机、搜索、调用命令行工具 |
| `app/makeicon.swift` | 生成 App 图标 |
| `app/build.sh` | 一键编译图标 + 工具 + App 包 |

## 原理

SSHYard 的密钥布局（参考其源码 `internal/keychain/encrypted.go`）：

1. 每个系统用户一把随机 32 字节主密钥，存在登录钥匙串，服务名 `com.sshyard.desktop`、账户 `master/v1`。
2. `secrets.enc` 的结构是 `SSHYARD-SECRETS\0` + 版本 + 24 字节 nonce + XChaCha20-Poly1305 密文。
3. 附加认证数据（AAD）是 `magic + 版本 + scope`，scope 取应用名（实测为 `SSHYard`），代码会依次尝试几个候选值。
4. 明文是一张 JSON 表：`host/<id>/password`、`host/<id>/key`、`host/<id>/passphrase`，共享凭据是 `cred/<id>/...`。
5. `hosts.json` 只有元数据（地址、用户、认证方式、所属凭据），所以列表本身不需要解密。

命令行用 cgo 直接调用 `SecKeychainFindGenericPassword`，拿到的是原始字节，不受命令行输出格式影响。

## 构建

依赖：Go 1.26+、Xcode Command Line Tools。

```sh
cd app && ./build.sh
```

产物：

- App：`~/Applications/SSHYard-密码获取器.app`
- 命令行：`~/.local/bin/sshyard-pass`

App 用 ad-hoc 签名，不需要 Apple 开发者账号，只在本机有效。

## 用法

图形界面：双击 App，列表里选主机，回车或双击即复制密码到剪贴板。

```sh
sshyard-pass --list                  # 列出全部主机
sshyard-pass --pick --copy           # 弹原生列表选择并复制
sshyard-pass 10.0.0.1                # 直接查某个 IP
sshyard-pass root@10.0.0.1 --copy    # 同 IP 多账号时指定账号
sshyard-pass 10.0.0.1 --field key    # 取私钥
sshyard-pass --export-key ~/.local/share/sshyard-pass/master.key
```

可用环境变量覆盖路径：`SSHYARD_HOSTS`、`SSHYARD_STORE`、`SSHYARD_KEY_CACHE`。

## 关于主密钥缓存

应用是 ad-hoc 签名，macOS 的钥匙串「始终允许」对它不生效，每次都会弹授权框。
所以 `--export-key` 会把主密钥写到权限 `600` 的缓存文件，之后优先读缓存。

这意味着：**能读这个文件的人就能解出你全部的 SSHYard 密码**。
它等价于一把没有口令的私钥。不想留就删掉，工具会回到钥匙串模式（恢复每次弹窗）。

## 注意

- 只读取 SSHYard 的数据，不写入、不修改。
- SSHYard 删除主机后，这里也查不到。
- 改密码不需要额外操作；但如果 SSHYard 重建了主密钥，需要删掉缓存重新 `--export-key`。
- SSHYard 的存储格式若变化，需要同步调整 `openStore` 的解析逻辑。
