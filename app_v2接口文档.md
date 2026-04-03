# App V2 接口文档 (加密通信协议 v2.0)

## 1. 协议概述

App V2 接口采用全量二进制加密通信，旨在通过多层混淆和加密机制，防止流量特征识别、重放攻击和中间人抓包。

### 1.1 通信层级
数据在传输过程中经过以下三层处理：
1.  **应用层 (JSON)**: 原始业务数据。
2.  **加密层 (AES-256-GCM)**: 提供机密性和完整性保护。
3.  **混淆层 (XOR + Reverse)**: 破坏数据结构和长度特征，抗深度包检测 (DPI)。

### 1.2 关键参数

| 参数 | 值 | 说明 |
| :--- | :--- | :--- |
| **AES Key** | `89A7B6C5D4E3F2019876543210ABCDEF1234562890ABCDEF89A7B6C5D4E3F201` | 32字节 (256-bit) Hex 字符串 (需 Hex Decode)。 |
| **AES Algorithm** | AES-256-GCM | 使用 GCM 模式，无需 Padding，自带数据完整性校验 (Tag)。 |
| **AES Nonce** | 12字节随机数 | 每次加密随机生成，拼接到密文头部。 |
| **Obfuscate Key** | `7M8N9B8V7C9X8Z7A9S8D7F9G8H7J9K8L7P9O8I7U9Y8W7T9R8P7M9N8B7V9C8X7Z9A8S7D9F8G7H9J8K7L6P` | 66字节 ASCII 字符串，用于滚动异或。 |

---

## 2. 算法实现细节

### 2.1 混淆算法 (Obfuscate)
**输入**: `Data` (字节数组)
**输出**: `ObfuscatedData` (字节数组)

**步骤**:
1.  **Rolling XOR**: 使用 66 字节 Key 对数据进行滚动异或。
    ```go
    for i, b := range Data {
        Data[i] = b ^ Key[i % 66]
    }
    ```
2.  **Reverse**: 将异或后的字节数组进行**首尾倒序**。
    ```go
    // [0x01, 0x02, 0x03] -> [0x03, 0x02, 0x01]
    for i, j := 0, len(Data)-1; i < j; i, j = i+1, j-1 {
        Data[i], Data[j] = Data[j], Data[i]
    }
    ```

### 2.2 去混淆算法 (Deobfuscate)
**输入**: `ObfuscatedData`
**输出**: `Data`

**步骤**:
1.  **Reverse**: 先将数据倒序还原。
2.  **Rolling XOR**: 再次进行滚动异或 (异或运算是可逆的：`A ^ K ^ K = A`)。

### 2.3 加密流程 (Request)
1.  **JSON**: 将请求参数序列化为 JSON 字符串。
2.  **Encrypt**: 
    - 生成 12 字节随机 `Nonce`。
    - `Ciphertext = AES_GCM_Seal(Key, Nonce, JSON)`。
    - `EncryptedData = Nonce + Ciphertext`。
3.  **Obfuscate**: 调用混淆算法处理 `EncryptedData`。
4.  **Send**: 将结果作为 HTTP Body 发送 (`Content-Type: application/octet-stream`)。

### 2.4 解密流程 (Response)
1.  **Receive**: 读取 HTTP Response Body。
2.  **Deobfuscate**: 调用去混淆算法还原 `EncryptedData`。
3.  **Decrypt**:
    - 提取前 12 字节作为 `Nonce`。
    - 剩余部分作为 `Ciphertext`。
    - `JSON = AES_GCM_Open(Key, Nonce, Ciphertext)`。
4.  **Parse**: 解析 JSON 数据。

### 2.5 错误处理
所有接口响应（包括 HTTP 200 业务成功、业务失败、以及 HTTP 4xx/5xx 系统错误）**均通过二进制加密流返回**。
客户端必须始终按照 **解密流程** 处理 Response Body。解密后的 JSON `code` 字段用于区分成功或失败。

- `code = 200`: 成功。
- `code != 200`: 失败，`msg` 字段包含错误信息。

---

## 3. 接口定义

### 3.1 设备登录/注册

- **URL**: `/app/v2/login`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| device_id | string | 是 | 设备唯一硬件标识符 | `android_id_123456789` |

**原始 JSON 示例**:
```json
{
    "device_id": "android_id_123456789"
}
```

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 (200: 成功) |
| msg | string | 提示信息 |
| data | object | 业务数据 |
| - id | int | 用户 ID |
| - dpid | int | 用户 dpid |
| - uuid | string | 用户 UUID |
| - email | string | 自动生成的邮箱 (`{device_id}@qq.com`) |
| - status | int | 账号状态 (1: 正常) |
| - quota | int64 | 剩余可用流量 (字节) |
| - token | string | 接口访问凭证 (Bearer Token) |
| - code | string | 邀请码 |
| - subscribe_url | string | **完整订阅地址** (用于获取节点配置) |
| - expire_time | string | 过期时间 (RFC3339) |

**原始 JSON 示例**:
```json
{
    "code": 200,
    "msg": "Login Success",
    "data": {
        "id": 1001,
        "dpid": 2001,
        "uuid": "550e8400-e29b-41d4-a716-446655440000",
        "email": "android_id_123456789@qq.com",
        "status": 1,
        "quota": 5368709120,
        "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
        "code": "A1B2C3D4",
        "subscribe_url": "https://api.vpn.com/s/A1B2C3D4",
        "expire_time": "2025-12-31T23:59:59+08:00"
    }
}
```

#### 错误响应 (Decrypted JSON)
> 注意：错误响应同样是经过 **混淆和加密** 的二进制流。客户端解密后可得到如下 JSON。

```json
{
    "code": 400,
    "msg": "Validation Error: DeviceID required",
    "data": null
}
```

### 3.1.1 检查更新

- **URL**: `/app/v2/update/check`
- **Method**: `POST`
- **Request Content-Type**: `application/octet-stream`
- **Auth**: Not Required

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| env | string | 是 | 运行环境，支持 `android / ios / windows`，
| version | int / string | 是 | 客户端当前版本号 | `100` |

**原始 JSON 示例**:
```json
{
    "env": "windows",
    "version": 100
}
```

#### 业务处理规则

1. 后端根据 `env` 映射到根目录 `update/{env}` 子目录：
   - 安卓 -> `update/android`
   - 苹果 -> `update/ios`
   - 电脑 -> `update/windows`
2. 每个环境目录下固定使用以下文件：
   - `version.json`：保存服务端最新版本号
   - `version.zip`：对应环境的更新压缩包
3. 后端读取客户端上传的 `version` 与对应环境目录中的 `version.json` 进行比对。
4. 若版本号一致，则返回加密后的 JSON 响应，表示当前已是最新版本。
5. 若版本号不一致，则直接返回对应环境的 `version.zip` 更新文件。
6. 若 `env` 无效、`version` 缺失或格式错误，则返回加密后的错误 JSON。

#### 版本一致时返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object | 结果对象 |
| - need_update | bool | 是否需要更新，固定为 `false` |
| - env | string | 标准化后的环境值 |
| - latest_version | int | 服务端最新版本号 |

**版本一致响应示例**:
```json
{
    "code": 200,
    "msg": "已是最新版本",
    "data": {
        "need_update": false,
        "env": "windows",
        "latest_version": 100
    }
}
```

#### 版本不一致时响应

- **HTTP Status**: `200`
- **Content-Type**: `application/zip`
- **响应内容**: 直接返回对应环境的 ZIP 更新包
- **响应头**:
  - `X-App-Update-Env`: 标准化后的环境值
  - `X-App-Update-Version`: 服务端最新版本号

### 3.2 获取用户实时信息 (流量/过期时间)

- **URL**: `/app/v2/user/info`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

**注意**: 此接口同样遵循 **二进制加密通信协议**。请求体虽为空（GET 请求），但响应体仍是加密混淆的二进制流。

#### 请求参数
无 (通过 Header 中的 Authorization 传递 Token)

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 (200: 成功, 404: 缓存不存在需重新登录) |
| msg | string | 提示信息 |
| data | object | 业务数据 |
| - quota | int64 | 剩余可用流量 (字节) |
| - expire_time | string | 过期时间 (RFC3339) |
| - expired_traffic_logs | array | 已过期流量包日志（读取后即删除） |
| - - id | int64 | 日志ID |
| - - label | string | 流量包标识 |
| - - traffic | int64 | 流量包流量（字节） |
| - - amount | float | 购买金额 |
| - - create_time | string | 日志创建时间 |
| - ads | array | 广告列表 |
| - - id | int | 广告ID |
| - - title | string | 广告标题 |
| - - image_url | string | 广告图片完整地址 |
| - - content | string | 广告内容 |
| - - link_url | string | 广告统计跳转链接（可直接交给 iOS / Android / Windows 浏览器打开） |

**说明**: 
- 此接口直接从 Redis 读取最新缓存数据，**不查询 MySQL**。
- 若 Redis 中无数据（缓存过期或未登录），将返回 404 错误，客户端应引导用户重新调用登录接口。
- 流量计算公式：`Available = TransferEnable - (U + D)`。
- 若存在 `user_traffic_log.valid_days = 0` 的当前用户日志，会在本次响应中通过 `expired_traffic_logs` 返回，并在返回后删除。
- 广告返回规则：
  - 默认返回所有启用广告
  - 若当前用户绑定代理 `users.dp_id` 对某广告主动关闭显示，则该广告不返回
  - 广告图片地址返回完整可访问 URL
  - `link_url` 返回的是后端统计跳转地址，不是原始广告地址
  - 客户端可直接把 `link_url` 交给系统浏览器 / WebView 打开，后端会先统计，再 302 跳转到真实广告地址

**原始 JSON 示例**:
```json
{
    "code": 200,
    "msg": "Success",
    "data": {
        "quota": 5368709120,
        "expire_time": "2025-12-31T23:59:59+08:00",
        "expired_traffic_logs": [
            {
                "id": 101,
                "label": "v2_invite_bonus",
                "traffic": 107374182400,
                "amount": 0,
                "create_time": "2026-03-22T09:00:00+08:00"
            }
        ],
        "ads": [
            {
                "id": 1,
                "title": "限时活动",
                "image_url": "https://api.vpn.com/uploads/ads/ad_123.png",
                "content": "",
                "link_url": "https://api.vpn.com/app/v2/ad/visit?token=xxx"
            }
        ]
    }
}
```

### 3.2.1 获取邀请信息

- **URL**: `/app/v2/user/invite/info`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| platform | string | 是 | 客户端平台，支持 `android / ios / windows / win / 安卓 / 苹果 / 电脑` | `android` |

**原始 JSON 示例**:
```json
{
    "platform": "android"
}
```

#### 业务处理规则

1. 服务端根据当前登录用户读取其 `users.id`。
2. 服务端根据当前登录用户的 `users.dp_id` 查询绑定代理 `admins.username`。
3. 礼品码按固定格式生成：`{users.id}invite{admins.username}`。
4. 服务端统一返回三端下载地址，均从 `config` 表读取：
   - Android: `android_down`
   - iOS: `ios_down`
   - Windows: 优先 `windows_down`，为空时回退 `win_down`
5. `content` 中的 `{download_url}` 会被替换为三行下载地址文本：
   - `Android：{android_download_url}`
   - `iOS：{ios_download_url}`
   - `Windows：{windows_download_url}`
6. 文案模板从后台“用户管理 -> 推广文案设置”读取，支持变量：
   - `{download_url}`
   - `{gift_code}`
7. 若后台未自定义模板，则使用默认模板：

```text
节点采用CN2 GIA + BGP
智能多线高端骨干网络承载
智能优化回国线路，无普通线路
无劣质中转线路、无超售拥堵
为你带来超低级延迟体验
支持开通专属的独享节点
下载地址：
{download_url}
填写礼品码：{gift_code}

你将免费获得100GB流量喔~
```

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object | 邀请信息 |
| - platform | string | 归一化后的平台值 |
| - android_download_url | string | 安卓下载地址 |
| - ios_download_url | string | iOS 下载地址 |
| - windows_download_url | string | Windows 下载地址 |
| - gift_code | string | 礼品码 |
| - invite_count | int64 | 当前用户已邀请人数 |
| - content | string | 最终推广文案 |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "成功",
    "data": {
        "platform": "android",
        "android_download_url": "https://api.vpn.com/download/android.apk",
        "ios_download_url": "https://api.vpn.com/download/ios",
        "windows_download_url": "https://api.vpn.com/download/windows.zip",
        "gift_code": "1001invite5oYSIxw0",
        "invite_count": 12,
        "content": "节点采用CN2 GIA + BGP\n智能多线高端骨干网络承载\n智能优化回国线路，无普通线路\n无劣质中转线路、无超售拥堵\n为你带来超低级延迟体验\n支持开通专属的独享节点\n下载地址：\nAndroid：https://api.vpn.com/download/android.apk\niOS：https://api.vpn.com/download/ios\nWindows：https://api.vpn.com/download/windows.zip\n填写礼品码：1001invite5oYSIxw0\n\n你将免费获得100GB流量喔~"
    }
}
```

**失败响应示例 (platform 无效)**:
```json
{
    "code": 400,
    "msg": "platform无效，仅支持 安卓/苹果/win",
    "data": null
}
```

### 3.2.2 广告统计跳转

- **URL**: `/app/v2/ad/visit?token={token}`
- **Method**: `GET`
- **Content-Type**: `text/html`
- **Auth**: Not Required

#### 调试环境 / Nginx 适配说明

- **本地调试环境**:
  - 直接访问后端地址即可，例如：`http://127.0.0.1:8080/app/v2/ad/visit?token={token}`
  - 若前端或测试页通过 Vite 代理访问后端，需确保 `/app/v2/` 已代理到 Go 服务
- **Nginx 正式环境**:
  - 需确保 `/app/v2/` 反向代理到后端 Go 服务
  - 需透传以下请求头，保证跳转地址、IP、UA 与 HTTPS 判断正确：
    - `Host`
    - `X-Real-IP`
    - `X-Forwarded-For`
    - `User-Agent`
    - `X-Forwarded-Proto`
  - 若广告图片使用本地上传文件，还需额外放行 `/uploads/` 静态目录，否则 `ads[].image_url` 会无法访问

#### 业务处理规则

1. `token` 由 `/app/v2/user/info` 返回的 `ads[].link_url` 内携带。
2. 客户端直接打开该地址即可，适配 iOS / Android / Windows 浏览器与 WebView。
3. 后端会先校验 token、用户、广告状态与代理显示状态。
4. 校验通过后：
   - 先执行广告点击统计
   - 再返回 `302 Redirect` 跳转到真实广告地址
5. 点击防刷使用 Redis 去重，维度为：
   - 广告ID
   - 代理AdminID
   - 日期
   - IP
   - UA Hash

### 3.2.3 获取工单状态

- **URL**: `/app/v2/user/ticket/status`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object | 工单状态 |
| - status | string | `idle / queued / active / closed` |
| - is_active | bool | 是否已接入人工 |
| - is_closed | bool | 当前工单是否已结束 |
| - queue_ahead | int | 前方等待人数 |
| - waiting_user | int | 当前排队总人数 |
| - latest_admin_message | object/null | 最近一条客服消息 |
| - - seq | int64 | 消息序号 |
| - - sender | string | 固定为 `admin` |
| - - content | string | 客服消息内容 |
| - - create_time | string | 客服消息时间 |

#### 业务处理规则

1. 工单状态与队列全部使用 Redis 存储，缓存 24 小时。
2. 同时仅处理一个活跃用户，其他用户进入等待队列。
3. `queue_ahead` 用于 App 提示“前面还有多少人”，避免多用户消息同时转发导致混乱。
4. `is_active`、`is_closed`、`latest_admin_message` 适合 App 轮询后直接驱动会话 UI。

### 3.2.4 获取工单消息

- **URL**: `/app/v2/user/ticket/messages`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object | 工单消息数据 |
| - status | object | 当前工单状态对象 |
| - messages | array | 工单消息列表 |
| - - seq | int64 | 消息序号 |
| - - sender | string | `user / admin / system` |
| - - content | string | 消息内容 |
| - - create_time | string | 消息时间 |

### 3.2.5 发送工单消息

- **URL**: `/app/v2/user/ticket/send`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| message | string | 是 | 用户发送的工单消息 | `你好，支付失败了` |

#### 业务处理规则

1. 消息写入 Redis，缓存 24 小时。
2. 若当前无活跃用户，则当前用户立即接入人工队列。
3. 若已有活跃用户，则当前用户进入排队队列。
4. 活跃用户消息会通过 Telegram 机器人转发给管理员，并强制管理员使用“回复”输入框回复。
5. Telegram 转发机器人从 `agent_telegram` 中选择：
   - 优先使用未失效机器人
   - 若转发失败，自动切换下一个机器人
   - 失败机器人会在 Redis 标记失效 60 分钟
   - 若当前无可用转发机器人，则接口仍成功写入消息，并返回系统提示：`人工客服未上班，请耐心等待`
6. 管理员聊天 ID 读取 `config.admin_telegram`。

### 3.2.6 结束工单

- **URL**: `/app/v2/user/ticket/close`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 业务处理规则

1. 用户可主动结束当前工单。
2. 管理员也可在 Telegram 中回复 `/end`、`结束`、`结束工单` 来结束当前工单。
3. 当前用户结束后，系统会自动从等待队列中取下一个用户接入。

### 3.2.7 申请设备绑定

- **URL**: `/app/v2/user/device-bind/apply`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

> 无必填字段，可传空对象 `{}`；服务端当前会直接按当前登录用户生成绑定链接。

#### 业务处理规则

1. 当前登录用户记为“用户A”。
2. 服务端校验用户A存在且状态正常。
3. 服务端生成一次性 `bind_token`，并写入 Redis，有效期 10 分钟。
4. 服务端返回 `bind_url`，客户端可直接将该链接生成二维码。
5. 其他设备上的用户B扫码后，使用自己的登录态访问 `bind_url` 即可完成绑定。
6. 绑定成功后，用户B后续再次调用 `/app/v2/login` 时，实际登录目标会切换为用户A，返回用户A的 `token / quota / subscribe_url / expire_time` 等信息。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object | 绑定申请结果 |
| - bind_token | string | 一次性绑定凭证 |
| - bind_url | string | 可直接用于生成二维码的链接 |
| - expire_time | string | 过期时间 (RFC3339) |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "成功",
    "data": {
        "bind_token": "UB8A7K2P1M9Q4R6T3W5Y7U9X",
        "bind_url": "https://api.vpn.com/app/v2/user/device-bind/scan?bind_token=UB8A7K2P1M9Q4R6T3W5Y7U9X",
        "expire_time": "2026-03-28T15:30:00+08:00"
    }
}
```

**失败响应示例 (账号禁用)**:
```json
{
    "code": 400,
    "msg": "账号已被禁用",
    "data": null
}
```

### 3.2.8 扫码确认绑定

- **URL**: `/app/v2/user/device-bind/scan`
- **Method**: `GET`
- **Auth**: Required (Bearer Token in Header，或 `token` Query 参数)

#### 请求参数 (Query)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| bind_token | string | 是 | 申请绑定接口返回的一次性凭证 | `UB8A7K2P1M9Q4R6T3W5Y7U9X` |

**Query 示例**:
```text
/app/v2/user/device-bind/scan?bind_token=UB8A7K2P1M9Q4R6T3W5Y7U9X
```

#### 业务处理规则

1. 当前扫码并发起请求的登录用户记为“用户B”。
2. 服务端根据 `bind_token` 从 Redis 读取目标用户A。
3. 若 `bind_token` 不存在或已过期，返回“绑定二维码已失效”。
4. 若用户B与用户A是同一人，返回“不能绑定自己”。
5. 服务端将 `users_device.user_id = 用户B.ID`，`users_device.bind_user_id = 用户A.ID`。
6. 若用户B之前已绑定其他账号，则本次扫码会直接覆盖为新的绑定目标。
7. 服务端删除本次 `bind_token`，避免重复使用。
8. 绑定成功后，用户B后续再次调用 `/app/v2/login` 时，实际返回用户A的登录信息。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object | 绑定结果 |
| - user_id | int | 当前扫码用户B的用户 ID |
| - bind_user_id | int | 绑定目标用户A的用户 ID |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "绑定成功",
    "data": {
        "user_id": 1002,
        "bind_user_id": 1001
    }
}
```

**失败响应示例 (二维码过期)**:
```json
{
    "code": 400,
    "msg": "绑定二维码已失效",
    "data": null
}
```

**失败响应示例 (绑定自己)**:
```json
{
    "code": 400,
    "msg": "不能绑定自己",
    "data": null
}
```

### 3.3 提交订单

- **URL**: `/app/v2/order/save`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| item | string | 是 | 套餐标识，对应 `node_item.label` | `500GB` |

**原始 JSON 示例**:
```json
{
    "item": "500GB"
}
```

#### 业务处理规则

1. 先判断当前登录用户 `dp_id` 是否等于 `-1`，若是则返回 `code=101`。
2. 校验 `item` 是否存在于 `node_item` 表 `label` 字段，不存在返回“套餐不存在”。
3. 校验通过后创建订单，返回订单号 `order_no`。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | string/null | 成功时为订单号 `order_no`，失败时为 `null` |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "订单创建成功",
    "data": "202603151742301234"
}
```

**失败响应示例 (dp_id = -1)**:
```json
{
    "code": 101,
    "msg": "dp_id无效",
    "data": null
}
```

**失败响应示例 (套餐不存在)**:
```json
{
    "code": 400,
    "msg": "套餐不存在",
    "data": null
}
```

### 3.4 提交卡密

- **URL**: `/app/v2/user/invite`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| invite | string | 是 | 卡密；支持普通卡密或复合卡密 | `5oYSIxw0` / `1033invite5oYSIxw0` |

**原始 JSON 示例**:
```json
{
    "invite": "5oYSIxw0"
}
```

**复合卡密示例**:
```json
{
    "invite": "1033invite5oYSIxw0"
}
```

> 说明：
> - 普通卡密格式：`真实卡密`
> - 复合卡密格式：`邀请人ID + invite + 真实卡密`
> - 例如 `1033invite5oYSIxw0` 中：
>   - `1033` 对应邀请人 `users.id`
>   - `invite` 为固定分隔符
>   - `5oYSIxw0` 对应真实卡密 `admins.username`

#### 业务处理规则

1. 判断 `invite` 是否提交，未提交返回“卡密不能为空”。
2. 先按普通卡密处理：根据 `invite` 查询 `admins.username`。
3. 若普通卡密不存在，则继续按复合卡密格式解析：`邀请人ID + invite + 真实卡密`。
4. 复合卡密场景下，继续验证真实卡密是否存在于 `admins.username`。
5. 复合卡密场景下，继续验证邀请人 ID 是否存在于 `users.id`；不存在返回“邀请人不存在”。
6. 将当前登录用户在 `users` 表中的 `dp_id` 更新为查询到的 `admins.id`。
7. 若复合卡密中的邀请人存在，则同时将当前登录用户在 `users` 表中的 `up_id` 更新为邀请人 `users.id`。
8. 给当前登录用户赠送 `100GB / 5天` 流量包，并写入 `user_traffic_log`。
9. 若复合卡密中的邀请人存在，则额外给邀请人赠送 `10GB / 5天` 流量包，并写入 `user_traffic_log`。
10. 清理相关订阅缓存后返回成功。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | null | 固定为 `null` |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "成功",
    "data": null
}
```

**失败响应示例 (invite 为空)**:
```json
{
    "code": 400,
    "msg": "卡密不能为空",
    "data": null
}
```

**失败响应示例 (invite 不存在)**:
```json
{
    "code": 400,
    "msg": "卡密不存在",
    "data": null
}
```

**失败响应示例 (邀请人不存在)**:
```json
{
    "code": 400,
    "msg": "邀请人不存在",
    "data": null
}
```

### 3.4.1 兑换卡密（新增）

> 说明：本节为**新增卡密兑换接口**。上面的 `3.4 提交卡密` 保持原逻辑不变，仍用于**新用户绑定赠送**流程，不做修改替代。

- **URL**: `/app/v2/user/agent-key/redeem`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| key | string | 是 | 卡密字符串，对应 `agent_key.key_code` | `AK8H2K9M3P7Q4R6T` |

**原始 JSON 示例**:
```json
{
    "key": "AK8H2K9M3P7Q4R6T"
}
```

#### 业务处理规则

1. 判断 `key` 是否提交，未提交返回“卡密不能为空”。
2. 根据 `agent_key.key_code` 查询卡密，不存在返回“卡密不存在”。
3. 若卡密已使用，返回“卡密已使用”。
4. 兑换成功后：
   - 增加当前用户 `user_traffic.quota`
   - 写入 `user_traffic_log`，记录流量包与有效天数
   - 将卡密标记为已使用，并记录 `used_user_id`、`used_user_email`、`used_time`
5. 返回兑换结果。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object/null | 成功时为兑换结果，失败时为 `null` |
| - package_name | string | 套餐名称 |
| - traffic_quota | int64 | 发放流量（字节） |
| - valid_days | int | 有效天数 |
| - used_time | string | 兑换时间 |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "兑换成功",
    "data": {
        "package_name": "100GB/30天卡密",
        "traffic_quota": 107374182400,
        "valid_days": 30,
        "used_time": "2026-03-26T12:00:00+08:00"
    }
}
```

**失败响应示例 (key 为空)**:
```json
{
    "code": 400,
    "msg": "卡密不能为空",
    "data": null
}
```

**失败响应示例 (卡密不存在)**:
```json
{
    "code": 400,
    "msg": "卡密不存在",
    "data": null
}
```

**失败响应示例 (卡密已使用)**:
```json
{
    "code": 400,
    "msg": "卡密已使用",
    "data": null
}
```

### 3.5 获取支付列表

- **URL**: `/app/v2/pay/list`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数
无 (通过 Header 中的 Authorization 传递 Token)

#### 业务处理规则

1. 查询 `pays` 表中 `status=1` 的记录。
2. 仅返回 `id`、`name` 字段。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | array | 支付方式列表 |
| - id | int | 支付方式 ID |
| - name | string | 支付方式名称 |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "获取成功",
    "data": [
        {
            "id": 1,
            "name": "支付宝"
        },
        {
            "id": 2,
            "name": "微信支付"
        }
    ]
}
```

### 3.6 订单发起支付

- **URL**: `/app/v2/order/checkout`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| method | string | 是 | 支付通道ID | `37` |
| trade_no | string | 是 | 订单号 | `2026031517735881879315` |
| type | string | 是 | 流量包类型（年/半年/季/月） | `月` |

**原始 JSON 示例**:
```json
{
    "method": "37",
    "trade_no": "2026031517735881879315",
    "type": "月"
}
```

#### 业务处理规则

1. 判断 `method` 是否提交，未提交返回“method不能为空”。
2. 判断 `trade_no` 是否提交，未提交返回“trade_no不能为空”。
3. 判断 `type` 是否提交，未提交返回“type不能为空”。
4. `type` 仅允许：`年`、`半年`、`季`、`月`，否则返回“type无效，仅支持 年/半年/季/月”。
5. 支付金额按 `type` 系数计算并保留两位小数：`月x1`、`季x1.8`、`半年x3`、`年x4.8`。
6. 自动换算并写入 `orders.description` 字段：`年->365`、`半年->180`、`季->90`、`月->30`。
7. 回调成功时流量日志有效期 `user_traffic_log.valid_days` 使用 `orders.description` 的换算值。
8. 业务处理参考 `/app/v1/user/order/checkout`：校验支付通道与订单归属，创建支付并返回支付地址。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object/null | 成功时为支付结果对象，失败时为 `null` |
| - pay_url | string | 支付地址 |
| - need_client_qrcode | int | 是否需要客户端提供二维码（`0`: 否，`1`: 是） |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "Checkout initiated",
    "data": {
        "pay_url": "https://pay.example.com/xxx",
        "need_client_qrcode": 1
    }
}
```

**失败响应示例 (method 为空)**:
```json
{
    "code": 400,
    "msg": "method不能为空",
    "data": null
}
```

**失败响应示例 (trade_no 为空)**:
```json
{
    "code": 400,
    "msg": "trade_no不能为空",
    "data": null
}
```

**失败响应示例 (type 为空)**:
```json
{
    "code": 400,
    "msg": "type不能为空",
    "data": null
}
```

### 3.7 查询订单状态

- **URL**: `/app/v2/order/detail`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Query)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| trade_no | string | 是 | 订单号 | `2026031517735881879315` |

#### 业务处理规则

1. 判断 `trade_no` 是否提交，未提交返回“trade_no不能为空”。
2. 业务处理参考 `/app/v1/user/order/detail`，按当前登录用户 + 订单号查询订单。
3. 返回该订单号对应的 `status`。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object/null | 成功时包含订单状态 |
| - status | int | 订单状态 |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "查询成功",
    "data": {
        "status": 1
    }
}
```

**失败响应示例 (trade_no 为空)**:
```json
{
    "code": 400,
    "msg": "trade_no不能为空",
    "data": null
}
```
