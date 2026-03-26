# Sandboxing AI agents, 100x faster

**Published:** March 24, 2026

**Authors:** Kenton Varda, Sunil Pai, Ketan Gupta

## Overview

Cloudflare has launched Dynamic Worker Loader, now in open beta for all paid Workers users. This feature enables execution of AI-generated code in lightweight, isolated environments called isolates—delivering performance improvements over traditional container-based approaches.

## Key Capabilities

### Performance Advantages

Dynamic Workers leverage V8 JavaScript isolates, the same sandboxing technology underlying Cloudflare's platform since its inception. The approach delivers:

- **100x faster startup:** Millisecond initialization versus container seconds
- **Memory efficiency:** Several megabytes versus hundreds for containers
- **On-demand execution:** New isolates spawn for individual requests without warm-keeping overhead

### Scalability & Latency

The system imposes no limits on concurrent sandboxes or creation rates. "Want to handle a million requests per second, where _every single request_ loads a separate Dynamic Worker sandbox, all running concurrently? No problem!" Isolates typically execute on the same machine as the creating Worker, eliminating cross-global communication delays.

### Security Architecture

Cloudflare implements defense-in-depth strategies:

- Rapid V8 security patch deployment (within hours)
- Custom second-layer sandbox with dynamic tenant cordoning
- Hardware-leveraging extensions using Memory Protection Keys
- Spectre-specific mitigations developed with academic researchers
- Malicious pattern scanning and automated blocking

## Developer Interface

### Dynamic Worker Loader API

The API accepts runtime-specified code within a Worker:

```javascript
let worker = env.LOADER.load({
  compatibilityDate: "2026-03-01",
  mainModule: "agent.js",
  modules: { "agent.js": agentCode },
  env: { CHAT_ROOM: chatRoomRpcStub },
  globalOutbound: null,
});

await worker.getEntrypoint().myAgent(param);
```

### TypeScript APIs Over HTTP

The platform emphasizes TypeScript interfaces for agent-accessible APIs, reducing token requirements compared to OpenAPI specifications. Agents invoke typed methods directly across RPC boundaries:

```typescript
interface ChatRoom {
  getHistory(limit: number): Promise<Message[]>;
  subscribe(callback: (msg: Message) => void): Promise<Disposable>;
  post(text: string): Promise<void>;
}
```

### HTTP & Credential Injection

Optional HTTP API support includes request interception for:
- Authorization header injection
- Request filtering and rewriting
- Direct response serving
- Request blocking

## Supporting Libraries

### Code Mode (@cloudflare/codemode)

Simplifies model-generated code execution against tool APIs, normalizing code formatting and managing sandbox construction with configurable network isolation.

### Worker Bundler (@cloudflare/worker-bundler)

Handles pre-bundling requirements by resolving npm dependencies, bundling with esbuild, and managing module maps for Dynamic Workers.

### Shell (@cloudflare/shell)

Provides agents virtual filesystem access within Dynamic Workers, backed by durable SQLite storage and R2 object storage, with structured typed methods replacing string parsing.

## Use Cases

**Code Mode:** Agents write single TypeScript functions chaining multiple API calls, reducing token usage and latency versus sequential tool invocation. Cloudflare's own MCP server exposes the entire Cloudflare API through two tools in under 1,000 tokens.

**Custom Automations:** Platforms like Zite enable users to build CRUD applications, connect third-party services, and execute backend logic through chat interfaces without direct code exposure.

**AI-Generated Applications:** Developers create platforms generating full applications from AI specifications, with cold-start performance enabling rapid development iteration and request interception maintaining safety.

## Pricing

Dynamic Workers cost $0.002 per unique Worker loaded daily (plus standard CPU and invocation charges). During the beta period, this fee is waived.

## Getting Started

Paid plan users access documentation and starter templates:
- **Dynamic Workers Starter:** Hello-world deployment example
- **Dynamic Workers Playground:** Runtime bundling and execution interface with real-time logging

The platform emphasizes JavaScript for on-the-fly code snippets due to inherent web sandboxing design and LLM training data prevalence, though Python and WebAssembly support exists for Workers generally.
