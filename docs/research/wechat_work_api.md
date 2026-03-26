# 企业微信 (WeCom) API Documentation

**官方文档:** https://developer.work.weixin.qq.com

## Authentication

### 获取 access_token

```
GET https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=ID&corpsecret=SECRET
```

Response:
```json
{
  "access_token": "token",
  "expires_in": 7200
}
```

## 消息收发

### 发送消息

```
POST https://qyapi.weixin.qq.com/cgi-bin/message/send
{
  "touser": "UserID",
  "toparty": "PartyID",
  "totag": "TagID",
  "msgtype": "text",
  "agentid": 1000001,
  "text": {
    "content": "Hello"
  }
}
```

## Message Types

| Type | Description |
|------|-------------|
| text | 文本消息 |
| image | 图片 |
| voice | 语音 |
| video | 视频 |
| file | 文件 |
| textcard | 文本卡片 |
| news | 图文消息 |
| markdown | Markdown消息 |
| miniprogram_notice | 小程序通知 |
| taskcard | 任务卡片 |

## Webhook Events

接收消息通过企业微信回调 URL:

```
POST /callback_url
{
  "msg_signature": "signature",
  "timestamp": "timestamp",
  "nonce": "nonce",
  "encrypt": "encrypted_content"
}
```

## User Management

- `user/create` - 创建成员
- `user/get` - 获取成员
- `user/update` - 更新成员
- `user/delete` - 删除成员
- `user/simplelist` - 获取部门成员

## Department Management

- `department/create` - 创建部门
- `department/get` - 获取部门信息
- `department/update` - 更新部门
- `department/delete` - 删除部门

## Agent Management

- `agent/get` - 获取应用详情
- `agent/set` - 设置应用
- `agent/list` - 获取应用列表

## Media Upload

```
POST https://qyapi.weixin.qq.com/cgi-bin/media/upload?access_token=TOKEN&type=TYPE
```

## OAuth2

- 授权登录: `https://open.weixin.qq.com/connect/qrconnect`

## Rate Limits

- Default: varies by endpoint
- Access token: 2000 requests/second

## Callback Configuration

企业微信支持回调模式接收消息，需要:
1. 配置回调 URL
2. 设置 Token 和 EncodingAESKey
3. 验证 URL 有效性
