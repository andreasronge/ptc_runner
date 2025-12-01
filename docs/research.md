Exploring an Elixir Version of the Open-PTC-Agent Framework

Background: Programmatic Tool Calling (PTC) and Open-PTC-Agent

Anthropic’s Programmatic Tool Calling (PTC) is a paradigm where an AI agent writes and executes code to use tools, instead of making individual JSON-based tool API calls ￼. This approach, introduced in late 2025, addresses major efficiency issues in AI agents. Traditionally, every tool’s full output is returned into the model’s context, which can flood the prompt with data. For example, analyzing 20 employees’ expenses might produce 2,000+ line items (over 110,000 tokens) in the prompt just to generate a summary. PTC avoids this by letting the model generate code that processes data in a sandbox and returns only the final result, yielding an 85–98% token reduction ￼. PTC leverages the fact that LLMs are very good at writing code to orchestrate complex workflows (using loops, conditionals, aggregations, etc.) rather than making one tool call at a time ￼. It shines especially for large structured data, time-series, or cases needing filtering/aggregation/visualization before returning results ￼.

Open-PTC-Agent (GitHub: Chen-zexi/open-ptc-agent) is an open-source implementation of Anthropic’s PTC concept in Python. It builds on LangChain’s DeepAgents and uses a Daytona sandbox for secure code execution ￼. The agent dynamically discovers the needed tools and writes Python code to call them ￼. That code runs in an isolated Daytona environment where the MCP (Model-Context-Protocol) tools are available as Python functions ￼. Only the final processed output (e.g. a summary or a filtered dataset) is returned to the LLM, not the raw data, greatly reducing context usage. Open-PTC-Agent automatically converts any MCP server’s tool schema into Python functions in the sandbox ￼. It also supports progressive tool discovery, meaning tools are loaded on-demand instead of upfront, saving prompt tokens ￼. Notably, the Daytona backend provides secure, isolated execution with filesystem sandboxing and snapshots ￼, so the AI-generated Python code can run safely without affecting the host system. This Python-based solution demonstrates the power of PTC: complex multi-tool workflows can be handled by code, keeping the LLM’s context lean and focused on the high-level reasoning.

The Case for a BEAM-Based PTC Implementation in Elixir

Given the benefits of PTC, you’re considering an Elixir/BEAM version of such a framework. There are a few motivations for this:
	•	Elixir Integration & Tech Stack Unity: If your application is primarily in Elixir (Phoenix, etc.), having the agent run entirely on the BEAM VM could simplify deployment and reduce external dependencies. It means not needing a separate Python runtime or bridging between Elixir and Python processes. An Elixir PTC agent could directly call your Elixir code or services as tools, potentially with less overhead than JSON HTTP calls.
	•	Concurrency and Throughput: The BEAM is known for lightweight concurrency. In theory, an Elixir-based sandbox might handle multiple concurrent code execution tasks more gracefully. You could spawn separate isolated processes for each “agent code” run. This would allow parallel use of the sandbox, handling multiple tool-calling workflows at once, which is aligned with Elixir’s strengths. (By contrast, Python’s GIL might limit true parallel CPU execution, though Python can use threads or asyncio for I/O concurrency.)
	•	Full Control Over Execution Environment: Since you are building your own MCP client and have control over how tools run, implementing the sandbox in Elixir gives you transparency. You can decide how to manage state (if any), how to limit resources, and how to integrate with Elixir logging/monitoring. In an all-BEAM solution, results from tools (which are stateless and require no external IO/network per your spec) can be handled entirely in-memory on the BEAM, possibly avoiding serialization costs.

It’s worth noting that direct analogues to open-ptc-agent in Elixir are not yet common, but the ecosystem is moving in that direction. For example, the Agent Jido framework is an autonomous agent system in Elixir (with tool/function calling support) and ReqLLM is a new library to interface with LLM providers (including OpenRouter) from Elixir ￼. These provide building blocks: ReqLLM can call models like OpenAI, Anthropic, etc., and supports function-calling tools via callbacks ￼. However, current Elixir libraries mostly implement standard function calling (where the LLM picks a tool and the function is executed immediately) rather than the code-generation approach of PTC. To date, no open-source Elixir project implements the full PTC pattern with an AI-written code sandbox, so pursuing this would be somewhat pioneering.

Safe Execution on the BEAM: Sandboxing Tools and Frameworks

A critical piece for a BEAM-based PTC agent is a sandboxed execution environment for running AI-generated code. Unlike Python (which can use containerized sandboxes like Daytona), the BEAM VM doesn’t natively provide strong sandboxing or privilege separation. In fact, the Erlang Ecosystem Foundation’s Security WG explicitly warns that “the BEAM runtime has very little support for access control… it is therefore not possible to isolate ‘untrusted’ processes in some sort of sandbox” within the same VM ￼. Any code running on the BEAM has essentially full access to the VM and host interface unless explicitly restricted. This means running LLM-generated Elixir/Erlang code directly via Code.eval* is unsafe ￼. To mitigate this, you must either restrict the code’s capabilities or execute it in an external isolated environment.

Existing tools for sandboxing Elixir code: One promising library is Dune, which is essentially an Elixir code sandbox. Dune evaluates untrusted Elixir code in an isolated process with a strict allowlist of modules and functions ￼. By default it disallows operations like file access, network, environment variables, and only permits safe modules (e.g., basic math, Enum, etc.) ￼. It also enforces resource limits: you can set a timeout, a maximum number of BEAM reductions (steps), and a memory limit for the execution ￼ ￼. Dune even prevents atom leaks and does not actually create new modules when the code defines a module (to avoid permanent VM changes) ￼. In short, it’s a best-effort in-VM sandbox: code runs in a separate process and is constrained by an allowlist and quotas. For example, File.cwd!() or any disallowed call will throw a DuneRestrictedError ￼. This could be a strong starting point for an Elixir PTC agent: the LLM-generated Elixir code can be run via Dune’s API (e.g. Dune.eval_string/2). Since your MCP tools need no external IO or network, you can whitelist just the functions that call those tools and basic stdlib. The sandbox process could then return the final result (or any captured output) to the main agent process.

However, Dune has important limitations. Its own documentation notes it cannot guarantee perfect security — an attacker might still find an escape, and if they do, they have full VM access ￼. It’s intended to block obvious escape paths, not withstand a determined malicious exploit. Additionally, Dune currently does not support concurrency or spawning new processes within the sandboxed code ￼. This means any Elixir code the LLM writes cannot launch its own parallel tasks (though you could still run multiple Dune evaluations in parallel from the outside). It also doesn’t support defining custom protocols or using advanced BEAM features in the sandbox ￼. These restrictions might be acceptable for your use case (since tool code likely just calls provided functions and manipulates data). But it’s a trade-off: the LLM’s code in Elixir might be somewhat less expressive than in an unrestricted Python environment.

Beyond Dune, there are other approaches: The EEF suggests using a dedicated embedded language for untrusted code ￼ – for instance, Lua. There’s a library called Luerl (Lua interpreter in Erlang) which allows running Lua scripts safely on BEAM. If an LLM can produce Lua code to call your tools, luerl would sandbox it by design (Lua can be restricted to prevent dangerous calls, and it runs as bytecode on BEAM). This might sound unconventional, but it aligns with the idea of an embedded runtime. Similarly, WebAssembly is an option: projects like Wasmtime/WasmEx in Elixir let you run compiled WASM code with strict sandboxing of memory and no access to the host unless permitted ￼. One could compile or interpret a simple language via WASM for safety. For instance, you could have the LLM output code in a language that targets WASM (or even use Python-to-WASM via tools like Pyodide) and run it with WasmEx. This provides very strong isolation (WASM or an external VM can enforce memory and prevent syscalls), but it adds complexity in getting the LLM to output the right kind of code.

Another heavy-duty approach is using container-based sandboxing with the BEAM. You could spin up a separate OS process (or even a lightweight VM like Firecracker) running an Elixir runtime for each code execution task. This is analogous to how Daytona likely works under the hood (each sandbox is isolated at the OS level). It guarantees malicious code can’t escape to your main application. In fact, one Elixir team reported success by running user code inside Docker containers controlled by a GenServer, achieving ~100–150µs execution overhead for a simple task after startup ￼. The trade-off is complexity: managing many short-lived BEAM VMs or containers (one per code execution) can be non-trivial and may impact performance if spin-up is frequent.

In summary, Elixir can run sandboxed code, but you will need to choose between an in-VM sandbox like Dune (convenient and lightweight, but with softer security guarantees) or a heavier external isolation (very secure, but more overhead). Many have concluded that in high-security use cases, an external sandbox (another VM, a hypervisor, or WASM) is the way to go ￼ ￼. For your scenario, since MCP tools are stateless and don’t require IO, using Dune with a strict allowlist (and perhaps additional safeguards like killing the process if it tries to consume too much CPU/memory) could suffice, as long as you trust the LLM not to be actively malicious. It’s a balance between security and performance.

BEAM Sandbox vs. Python Sandbox: Pros and Cons

Pros of a BEAM-based sandbox and Elixir PTC agent:
	•	Native Integration & Control: You can keep everything in Elixir/BEAM, leveraging OTP supervision, monitoring, and familiar tools. The sandbox can be an Elixir process (or node) that you supervise, making it easier to restart or limit (using OTP tools) if something goes wrong. There’s no need to run a separate Python interpreter or maintain a Python environment, simplifying deployment.
	•	Concurrency and Scaling: The BEAM excels at running many lightweight processes. If you need to handle multiple tool-calling tasks concurrently, you can spin up multiple sandbox processes easily. Each Dune evaluation or each external sandbox VM could be managed by an Elixir Task or GenServer. This fits well with an environment like Phoenix handling many requests – each request that requires an AI code execution could get its own isolated process. In contrast, a Python sandbox like Daytona might rely on threading or separate subprocesses; Elixir’s scheduling might handle bursty loads more gracefully.
	•	Performance for Orchestration: If the AI-generated code is mostly orchestrating API calls (to MCP tools) and doing light data manipulation, an Elixir implementation could be quite efficient. Elixir’s binary handling and pattern matching are fast for text or moderate data processing. Also, no context-switch to an external language means low overhead when moving data between your app and the sandbox (e.g., you might pass in JSON data to the sandbox as an Elixir map, process it, and get results, without serializing over HTTP as you might with a Python microservice).
	•	Leverage BEAM Fault-tolerance: The sandbox can be designed to fail fast and not bring down the system. For example, if the LLM writes an infinite loop, the reductions limit in Dune will halt it ￼, and you can trap that exit and send an error back to the LLM. The BEAM is built to handle millions of processes, so even if an agent spawns a few processes for a task, it’s manageable.

Cons and challenges of a BEAM sandbox vs a Python sandbox:
	•	Security and Isolation: As noted, a Python sandbox (like Daytona) often runs code in a truly isolated environment (chroot jail, container with no network, etc.), so even if the code is malicious it can’t harm the host. On BEAM, true isolation is hard without using external containers. An in-VM Elixir sandbox (Dune) relies on language-level restrictions which might not catch a very clever escape. If an LLM somehow finds a loophole in the allowlist or a vulnerability in the sandbox implementation, the entire BEAM VM could be compromised. This is a serious consideration if you treat the LLM’s output as untrusted. In short, the Python sandbox approach may offer a stronger security sandbox by default. Running untrusted code on BEAM “should not be considered fully safe” in production ￼, whereas tools like Daytona are designed for that purpose with more guarantees.
	•	LLM Proficiency and Libraries: Arguably the biggest practical hurdle is that current LLMs are far more familiar with Python for coding tasks than Elixir. Models like GPT-4 or Claude have been trained on tons of Python data science and scripting examples, but relatively fewer examples of Elixir code. They likely don’t know Elixir’s standard library or data manipulation libraries nearly as well. For instance, an LLM asked to “plot a chart of this time series data” will confidently produce Python code using matplotlib or pandas, but it may not even know about Elixir’s equivalents (such as VegaLite or Explorer/Nx for dataframes). You would have to carefully prompt or fine-tune the model to use any Elixir data libraries you want to support. Even basic tasks in Elixir (like string handling, Enum functions) might require some prompt priming for the model to recall syntax. This could result in more mistakes or slower iterations, reducing the efficiency gains of PTC. By contrast, Python PTC can tap into the model’s strong latent knowledge of Python packages to, say, sort CSV data or compute statistics with NumPy. With Elixir, the model might be limited to the functions you explicitly allow and describe. You might end up implementing more logic in the sandbox host and having the LLM just call those, reducing the “free-form code” advantage.
	•	Ecosystem for Data Processing: Building on the above, if your use cases involve heavy data analysis or visualization, Python’s ecosystem is unparalleled. The open-ptc-agent leverages this – it can, for example, use Pandas to filter a big table, then maybe matplotlib to create a chart, all within the sandbox, and then return an image or summary. In Elixir, while we have libraries (Nx, Explorer for dataframes, etc.), they are not as mature or as widely known to LLMs. You may need to introduce custom tools for complex tasks (e.g., instead of having the LLM write code to draw a chart, you might provide a high-level “plot_chart(data)” function as a tool because expecting it to write VegaLite scripts might be unrealistic). Essentially, the Python sandbox is more flexible for arbitrary code the model might come up with, whereas an Elixir sandbox might need a more curated approach (with the model calling into known allowed functions more often).
	•	Development Effort: Since there’s no ready-made Elixir PTC framework, you would be creating a lot from scratch. You’d need to implement functionality analogous to what open-ptc-agent provides:
	•	Discovering available MCP tools and generating Elixir function stubs or modules for them (similar to how open-ptc-agent auto-generates Python functions from MCP schemas ￼). In Elixir, you could generate module definitions or use anonymous functions in a context that the sandbox can call. This is doable (for example, reading a JSON schema and producing Elixir code), but it’s added work.
	•	A mechanism to feed those generated functions into the sandbox environment. Dune does not allow defining actual new modules in the sandbox (to avoid leaking state) ￼ ￼, so you might have to inject a pre-built context. Perhaps you’d pass the MCP tool functions in via the allowlist or as part of the evaluation binding. (One idea: use Dune’s support for a persistent session – Dune.Session – to pre-load tool function definitions as variables in that session before letting the LLM code run.)
	•	Handling of multi-step agent logic: if the code fails or produces an error, you need to capture that and decide if the LLM should get the error message to try to fix its code (similar to how a Python agent would iterate). This involves prompt engineering around error output. You’ll also need to manage timeouts (to prevent hanging code) and perhaps cancellation if a user aborts a request.
	•	Features like file I/O in the sandbox: open-ptc-agent’s sandbox writes files to a data/ directory for results ￼. In an Elixir sandbox, you might implement something similar (perhaps allow writing to an in-memory filesystem or a temp directory). Dune by default disallows File access ￼, but you might selectively allow a stubbed File module that only writes to a safe location. This is non-trivial but possible (or you keep everything in memory and return data directly).
	•	If you want image outputs (charts), you’d need to decide how to support that. Python can easily save a plot to a PNG. Elixir could call out to gnuplot or VegaLite, but again the LLM would need to know how. Alternatively, you treat chart generation as a tool function implemented in the host (the LLM just calls plot_data() which you implement using VegaLite under the hood, then have it return an image blob).
	•	Concurrent Sandbox Use: You mentioned interest in concurrent usage of the sandbox. With Python/Daytona, one might spawn multiple sandbox instances or threads to handle simultaneous agent requests. On BEAM, you can definitely spawn multiple Dune executions concurrently (each in its own process). That is a pro, but note that each one will consume CPU schedulers on the BEAM. If the AI code does heavy computation, many concurrent executions could strain the VM (just like many Python processes would strain CPU). One caveat: if your LLM tries to do parallel calls within the code (say, spawn processes to call multiple tools concurrently), a Python agent could potentially use threading or asyncio to do that, whereas an Elixir agent within Dune cannot spawn (since concurrency is restricted). So the model’s code itself would likely be sequential in Elixir. You could mitigate this by having the agent framework handle parallelism: e.g., if the model wants to fetch data from two MCP tools concurrently, you could have it call a provided parallel(fetch1(), fetch2()) function that you implement to run two tool calls in parallel on the host and then return results. But that would be a custom extension – not impossible, but requires designing the API that the LLM uses.

In summary, a BEAM sandbox can work and offers integration and concurrency benefits, but Python remains the path of least resistance for PTC due to the LLM’s familiarity and rich libraries. Security-wise, a Python sandbox (done properly) has an edge unless you put comparable effort into OS-level isolation for the BEAM.

Feasibility and Alternatives

Building an Elixir equivalent of open-ptc-agent is feasible but will be a significant effort. The lack of existing frameworks means you’ll be trailblazing many components. Some of the toughest challenges will be guiding the LLM to produce valid Elixir code and ensuring the sandbox is safe yet functional enough. You should be prepared for a lot of prompt experimentation so that the model knows how to use your custom tool functions and stays within allowed operations. There’s also the maintenance aspect: open-ptc-agent and Anthropic’s PTC are evolving rapidly. If you implement an Elixir version, you’ll need to keep up with improvements (for example, Anthropic might introduce new features like tool use examples or better error handling, which you’d have to manually incorporate).

It’s worth questioning why such a library may not already exist or could be a “bad idea.” One reason is simply the smaller audience – the intersection of people who need LangChain-style agents and who use Elixir is not huge, so most effort has gone into Python. Additionally, as discussed, Python is just easier for the model to work with when it comes to arbitrary coding. Another consideration: Anthropic’s Claude (and possibly other LLMs) may soon offer PTC functionality directly. The Anthropic blog indicates these features (Tool Search, Programmatic Tool Calling, etc.) are part of Claude’s developer platform ￼ ￼. If you use Claude via OpenRouter, you might eventually get the benefit of Claude writing and executing code on Anthropic’s side, without you implementing it. (As of now, Claude’s “Code Interpreter” style capabilities are in beta, but if they become widely available, an Elixir library duplicating that could be redundant.) OpenAI has not announced a direct equivalent to PTC yet – they rely on function calling and have the Code Interpreter as a separate product – so for GPT-4 you would still need your own sandbox approach.

Alternative approaches: If creating a full PTC system in Elixir is too onerous, consider a hybrid solution. For instance, you could run the open-ptc-agent Python service alongside your Elixir application. Your Elixir code could invoke it (e.g., via an HTTP API or RPC) whenever a task requiring heavy tool orchestration arises. Essentially, Elixir would delegate those queries to the Python agent. This gives you PTC benefits with minimal development, at the cost of running a Python component. If you truly want everything on the BEAM, another alternative is using a restricted language for the agent’s code. As mentioned, Lua on BEAM might be a sweet spot: LLMs do know Lua to some extent (not as well as Python, but better than Elixir), and Lua is simpler (no concurrency, no direct OS access unless allowed). You could expose your MCP tools to Lua (via Luerl’s API bridging) and prompt the LLM to write Lua scripts to use them. This would run safely inside the VM (Lua can be sandboxed thoroughly) ￼. The downside is you introduce a new language into the mix and would need to prompt the LLM accordingly (“Here are functions X, Y in Lua…”). But it aligns with EEF’s guidance to use a purpose-built embedded language for sandboxing ￼.

One more relevant point: you mentioned integration with OpenRouter and keys. This part should be straightforward – whether you use Python or Elixir, you’ll call an API to an LLM. In Elixir, as noted, you can use libraries like ReqLLM (by Agent Jido) to manage API calls to providers including OpenRouter ￼ ￼. OpenRouter will allow you to access models like OpenAI’s or Anthropic’s through a unified API, and you can specify the model (e.g. "anthropic:claude-2" or others) in your calls. So LLM integration in Elixir is already solved by existing packages; the main task is connecting the LLM’s outputs to your sandbox execution loop.

In conclusion, creating an Elixir PTC-agent library is an ambitious but potentially rewarding project. You would be combining advanced concepts – sandboxing on BEAM, dynamic codegen, and tool integration – which is complex. There are no off-the-shelf Elixir equivalents of open-ptc-agent yet, so you’ll be breaking new ground. The pros are deeper control and BEAM-native operation, while the cons include security caveats ￼ ￼ and the LLM’s weaker familiarity with Elixir. If security is paramount, you might stick to a proven Python sandbox (or ensure your BEAM sandbox is truly isolated via OS processes or WASM). If you proceed in Elixir, leverage the existing building blocks: Dune for execution isolation ￼, ReqLLM/OpenRouter for model calls, and perhaps Agent Jido’s framework for overall agent structure. Keep the scope realistic – you might start by supporting just the patterns you need (e.g., data filtering tools) and gradually expand. Also be ready to invest in prompt design so the model knows how to “program” in the environment you create. There’s no fundamental reason a BEAM sandbox PTC won’t work, but it does trade convenience for control. Consider whether the benefit (not having a Python dependency and running on BEAM) outweighs the development effort and potential model limitations. In many cases, engineers have opted for the simpler route of using Python for these “AI coder” scenarios, given how adept LLMs are with it ￼. But if your situation calls for an all-Elixir solution (for scalability or architectural reasons), it’s certainly possible – just proceed with eyes open about the challenges and use the community’s prior work (sandbox libs, LLM clients) to your advantage.

Sources:
	•	Anthropic, “Code execution with MCP: Building more efficient agents”, Nov 2025 – discusses how writing code in a sandbox addresses tool usage token costs ￼ and introduces the open standard Model-Context-Protocol (MCP) ￼.
	•	Chen Zexi, Open PTC Agent – GitHub README (2025) ￼ ￼ ￼ – describes the open-source Python implementation of Programmatic Tool Calling, its benefits, and use of the Daytona secure sandbox.
	•	Functional Rewire, Dune README (Elixir Sandbox Library) ￼ ￼ – explains features and limitations of the Dune sandbox for evaluating untrusted Elixir code (allowlisted modules, no file/network access, no full guarantee of security).
	•	EEF Security WG, “Sandboxing Untrusted Code” (Guidelines, 2021) ￼ – warns that the BEAM cannot isolate untrusted code internally and recommends using an external runtime (e.g. Lua) for sandboxing in Erlang/Elixir.
	•	Agent Jido, ReqLLM Announcement (2025) ￼ ￼ – introduces an Elixir library for LLM interactions (OpenAI, Anthropic, OpenRouter, etc.) and demonstrates tool/function calling setup in Elixir.


Creating a simple custom language (a mini-DSL) in Elixir using metaprogramming is not only possible, but in many ways the ideal solution for an Elixir-native PTC-like system.

This approach neatly avoids BEAM sandboxing limitations, avoids running arbitrary Elixir code, and gives the LLM a clear, safe, controlled grammar to express computations and tool calls.

Below is a structured answer:

⸻

✅ Why a Custom DSL Is a Great Strategy

Instead of letting the LLM generate arbitrary Elixir (unsafe + LLM is weak at Elixir), you define a small, safe “programming language” tailor-made for tool calling and data manipulation.

Advantages:

1. You control the grammar → maximum safety

LLM produces DSL expressions, not raw Elixir.
You build a small interpreter that only handles allowed operations.

No BEAM runtime access → no security issues.
No need for full sandboxing.

2. LLMs excel at following restricted grammars

PTC works best when the model writes structured code.
A small DSL is easier for a model to learn than a large unfamiliar language like Elixir.

3. You can design it around MCP tools

Example DSL programs:

load(:expenses) 
|> filter(category: "travel") 
|> sum(:amount)

or S-expression style:

(sum 
   (filter expenses (eq category "travel"))
   amount
)

or JSON-like:

{
  "action": "sum",
  "data": {
    "from": "expenses",
    "filter": {"category": "travel"}
  },
  "field": "amount"
}

4. You keep execution on BEAM

The interpreter is pure Elixir and runs inside a supervised process.
Zero Python/sandbox overhead.

5. Perfect control over performance

You can optimize specific operations using:
	•	Nx (numerical compute)
	•	Explorer (dataframes)
	•	Flow or Broadway for streaming datasets

6. The DSL is deterministic

Everything executed is something you wrote in Elixir—no unpredictable code from the model.

⸻

🔍 Existing Patterns / DSL Projects to Learn From

Elixir has many DSLs, and they show how to build simple languages with macros.

You can learn from:

1. Ecto Query DSL

from u in User, where: u.age > 18

Good example of AST-building macros.

2. Phoenix Router

get "/users", UserController, :index

Example of a domain-specific declarative language.

3. Absinthe GraphQL Language

Large and powerful DSL implemented in Elixir.

4. NimbleParsec

Used to create parsers. Perfect for parsing your custom DSL text into AST.

5. Witchcraft / Hologram

These explore functional languages and AST manipulation on BEAM.

6. Eml or Sourceror

Tools for building or manipulating Elixir ASTs.

All of these show techniques you can reuse to build a small language.

⸻

🧪 Recommended Architecture for a DSL-based PTC Agent

This is how I’d design it for your BEAM-native “PTC”.

⸻

1. Define DSL Syntax

Pick one style:

Option A) Piped commands

load(:expenses) |> filter(:category, "travel") |> sum(:amount)

Option B) S-expressions

(sum (filter expenses (eq category "travel")) amount)

Option C) JSON (easiest for LLMs)

{
  "op": "sum",
  "args": {
    "filter": ["category", "travel"]
  }
}

I recommend JSON DSL first—LLMs are excellent at it.

⸻

2. Implement a Parser

If JSON:
No parsing needed, just decode → Elixir map.

If text DSL:
Use NimbleParsec — fast, safe.

⸻

3. Build a Small Interpreter

Example:

defmodule MiniLang.Exec do
  def eval(%{"op" => "sum", "args" => args}, env) do
    data = resolve(args["data"], env)
    field = args["field"]
    Enum.reduce(data, 0, &(&1[field] + &2))
  end
end

Everything the model can “run” is backed by your safe functions.

⸻

4. Attach MCP tools

Expose each MCP tool as a DSL function:

{
  "op": "tool_call",
  "name": "getUsers",
  "args": {"limit": 50}
}

Interpreter dispatches to your tool client.

⸻

5. Use OpenRouter / ReqLLM for LLM backend

ReqLLM supports OpenRouter:

ReqLLM.openrouter("qwen2.5-7b", messages: [...])


⸻

6. Make the agent loop

Model writes DSL program → you parse → eval → return result → possibly ask for refinement (multi-turn).

⸻

⚖️ Why DSL > sandboxed Elixir for PTC

Approach	Pros	Cons
Run arbitrary Elixir code	More flexible	Dangerous, hard to sandbox, LLM is weak at Elixir
Use Dune sandbox	Some isolation	Still unsafe, no concurrency, limited, complex
Custom DSL	Safe, simple, controllable, LLM-friendly, BEAM-native, predictable	Less flexible than Python, you must design DSL

A DSL is strictly superior for safety, reliability, and model compliance.

⸻

🧠 Does any similar Elixir DSL already exist?

Not for PTC, but the following are good templates:
	•	LiveView DOM DSL
	•	Ecto Query DSL
	•	Absinthe GraphQL DSL
	•	Commanded event DSL
	•	Scenic UI DSL
	•	Surface component DSL
	•	NimbleParsec-powered DSLs (many examples)

None are a PTC interpreter—but they prove DSL creation is idiomatic in Elixir.

⸻

🚀 Recommendation

I strongly recommend building:

✔ A small JSON-based DSL

✔ A BEAM interpreter for it

✔ Integrations with your MCP tools

✔ An LLM prompt like:

“Always produce valid JSON DSL using the following schema…”

This gives you:
	•	maximum safety
	•	minimum implementation complexity
	•	high model accuracy
	•	pure BEAM execution
	•	no sandboxing worries

This is exactly how Google’s Gemini PTC, Anthropic’s Python PTC, and OpenAI Advanced Tools work under the hood—DSL + interpreter, not general-purpose code execution.

⸻

❓ Want next steps?

I can generate:

✅ DSL design (syntax + grammar)
✅ Interpreter skeleton in Elixir
✅ Prompt templates for LLMs
✅ Examples of tool calls + workflows
✅ Security checklist
✅ Comparison of JSON-DSL vs S-expression vs pipe DSL

    