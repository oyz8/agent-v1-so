## main.so 全版本合集

本 Release 由 GitHub Actions 自动编译生成，包含 **glibc** 和 **musl** 两套原生扩展。

### 文件命名

| 文件名 | 适用环境 |
|---|---|
| `main-{python}-{arch}.so` | glibc（VPS / Debian / Ubuntu / CentOS） |
| `main-{python}-{arch}-musl.so` | musl（Alpine / Unikraft Cloud） |

### 架构与 Python 版本

- 架构：`amd64`、`arm64`
- Python：`3.8`、`3.9`、`3.10`、`3.11`、`3.12`、`3.13`（musl 版本到 `3.13`）

### 使用方法

#### VPS（glibc）

```bash
export NZ_SERVER="nezha.xxx.com:443"
export NZ_CLIENT_SECRET="your_secret"
export NZ_UUID="your_uuid"
curl -sSL https://raw.githubusercontent.com/oyz8/agent-v1-so/main/install.sh | sh
