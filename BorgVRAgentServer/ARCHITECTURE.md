# Model endpoint

The name of this deployment directory is retained so existing checkouts can use
their configuration and model cache. It no longer contains an agent runtime.

The Swift assistant in BorgVR calls a vLLM model through an authenticated HTTPS
endpoint. Compose runs the official vLLM image on the selected hardware and a
standard nginx proxy for transport only. The proxy exposes exactly the model
list and Chat Completions paths. The vLLM port is not published. BorgVR owns
all goals, tool execution, permissions, state revisions and cancellation.
OpenAI is an alternative endpoint called directly by the app and does not use
this deployment. See the [client architecture](../AppSupport/Voice/ARCHITECTURE.md).
