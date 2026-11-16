# perant_gateway

GPL-3.0-only 的 Dart HTTP/SSE 传输包。支持 OpenAI 格式的 Chat Completions 与 Responses，不依赖界面或原生 Linux。

## 已实现

- 流式 UTF-8、CRLF、注释和多行 SSE 解析，以及事件/工具参数大小限制。
- 文本增量、完整工具提案、正常完成、用户取消和中断错误。
- Chat 多轮所需的 assistant/工具/推理扩展字段；Responses 原生 output 上下文。原始元数据只作为内存数据返回，不自动持久化或记录。
- 可注入 `http.Client` 的请求取消、连接/空闲超时、HTTP 错误脱敏和固定文本连接测试。
- HTTPS 默认；本机 loopback HTTP 可用于开发。禁止自动跟随重定向，避免凭据转发给其他入口。

## 使用边界

`GatewayToolCall` 只是模型提出的调用，**本包从不执行工具**。调用方仍须校验参数、授权、文件范围和任务状态。只有收到终止标记才返回 `GatewayCompleted`；断流不会被误认为任务已完成。

输入通过 `GatewayRequest.input` 保留各协议的原生消息或 Item。`GatewayCompleted.continuation` 在 Chat 模式包含 `assistantMessage`，在 Responses 模式包含完整 `response`，供调用方按该协议继续上下文。不要将两种协议的历史直接混用。

API Key 通过 `stream`/`testConnection` 参数注入，不写入 `GatewayConfiguration`。请求头中的其他敏感认证方式不属于此版接口；配置头只接受非敏感扩展字段。异常不会包含服务原始响应、地址或 Key。

连接测试会向用户选定服务发送固定的 “Reply with the single word OK.”，没有文件、工具或私人材料；正常 token 费用仍可能产生。`dart test` 只使用本地 MockClient，不需要也不读取任何 API Key。

## 真实服务检查

`tool/live_check.dart` 用本包向真实服务发送固定的非私人提示，依次检查连接测试、两轮对话（第二轮回放保存的 assistant 消息）、工具提案和工具结果往返。它会产生少量真实 token 费用，Key 只从环境变量读取，不打印、不落盘：

```sh
cd packages/perant_gateway
PERANT_LIVE_API_KEY=… PERANT_LIVE_MODEL=deepseek-chat ../../tool/dartw run tool/live_check.dart
```

可选 `PERANT_LIVE_BASE_URL`（默认 DeepSeek）、`PERANT_LIVE_PROTOCOL=responses`、`PERANT_LIVE_VERBOSE=1`。请求被拒绝时会输出状态码和服务返回的错误文字，便于定位配置问题。2026-11-16 已用 DeepSeek `deepseek-chat` 的 Chat Completions 跑通全部 5 项；其他供应商和 Responses 协议尚未用真实 Key 验证。

这个包不包含任务编排、云端授权 UI、凭据持久化、供应商自动回退、工具执行循环或文件处理。

## 协议依据

- [OpenAI 工具调用](https://developers.openai.com/api/docs/guides/function-calling)
- [Chat Completions 流事件](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)
- [Responses 流事件](https://developers.openai.com/api/reference/resources/responses/streaming-events)

部分 OpenAI 模型的工具调用要求 Responses。兼容服务的具体参数与能力应由上层供应商预设指定，不能仅凭地址或模型列表认定完整兼容。
