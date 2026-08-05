## 使用文档

### VPS快速安装（推荐）

```bash
export NZ_SERVER=nezha.com:443 NZ_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxx NZ_UUID=01207278-7913-405c-a7be-f19665dc9c17
curl -sSL https://raw.githubusercontent.com/oyz8/agent-v1-so/main/install.sh | sh
```

> 不需要再设置 `NZ_TLS`，Agent 会自动处理。

---

### 1. 依赖安装

运行时需要的 Python 库（`install.sh` 会自动安装）：

`requirements.txt`
```txt
grpcio
grpcio-tools
protobuf
pyyaml
psutil
aiohttp
```

---

### 2. 配置加载优先级

Agent 使用以下优先级（高→低）解析配置：

1. **环境变量** `NZ_<字段名>`（如 `export NZ_SERVER="..."`）  
2. **配置文件** `config.yml`（通过 `config_path` 参数指定）  

> TLS 现在由 Agent **自动判断**：根据服务器端口是否在 TLS 常用端口列表中决定是否启用 TLS，无需手动配置。

---

### 3. 启动方式

#### 方案一：使用 `run.py` 脚本

**最小化启动（仅依赖环境变量）**

```python
import sys
from main import WorkerApp

if __name__ == "__main__":
    app = WorkerApp(config_path=None)   # 不读配置文件
    sys.exit(app.run())
```

配合环境变量：
```bash
export NZ_SERVER="nezha.com:443"
export NZ_CLIENT_SECRET="your_secret"
export NZ_UUID="your_uuid"
nohup python3 run.py > /dev/null 2>&1 &
```

**使用 `config.yml`**

```python
import sys
from main import WorkerApp

if __name__ == "__main__":
    app = WorkerApp(config_path="config.yml")
    sys.exit(app.run())
```

`config.yml` 示例（最小内容）：
```yaml
server: "nezha.com:443"
client_secret: "your_secret"
uuid: "your_uuid"
```

#### 方案二：内联启动（无需额外文件）

直接通过命令行启动：
```bash
export NZ_SERVER="nezha.com:443"
export NZ_CLIENT_SECRET="your_secret"
export NZ_UUID="your_uuid"

nohup python3 - > /dev/null 2>&1 <<'PYEOF' &
import sys
from main import WorkerApp

app = WorkerApp(config_path=None)
sys.exit(app.run())
PYEOF
```

---

