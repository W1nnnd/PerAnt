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

连接测试会向用户选定服务发送固定的 “Reply with the single word OK.”，没有文件、工具或私人材料；正常 token 费用仍可能产生。代码测试仅使用本地 MockClient，未使用真实 API Key、未验证各家付费模型。

这个包不包含任务编排、云端授权 UI、凭据持久化、供应商自动回退、工具执行循环或文件处理。

## 协议依据

- [OpenAI 工具调用](https://developers.openai.com/api/docs/guides/function-calling)
- [Chat Completions 流事件](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)
- [Responses 流事件](https://developers.openai.com/api/reference/resources/responses/streaming-events)

部分 OpenAI 模型的工具调用要求 Responses。兼容服务的具体参数与能力应由上层供应商预设指定，不能仅凭地址或模型列表认定完整兼容。
