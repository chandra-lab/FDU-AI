"""Run inside a container on the university-ai network: checks the backend's path to Model Runner.

Usage: python net-check.py <base_url> <model_id>
"""
import json
import sys
import urllib.request

base, model = sys.argv[1].rstrip("/"), sys.argv[2]
with urllib.request.urlopen(base + "/models", timeout=10) as r:
    ids = [m["id"] for m in json.load(r)["data"]]
if model not in ids:
    print(f"FAIL {model} not in {ids}")
    sys.exit(1)

body = json.dumps({
    "model": model,
    "max_tokens": 8,
    "messages": [{"role": "user", "content": "Say OK."}],
    "chat_template_kwargs": {"enable_thinking": False},
}).encode()
req = urllib.request.Request(base + "/chat/completions", data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=120) as r:
    content = json.load(r)["choices"][0]["message"]["content"]
print(f"OK {base} serves {model}: {content.strip()!r}")
