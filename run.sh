#!/bin/bash
# The assistant's language model: llama.cpp's server, speaking the OpenAI chat API, on the GPU.
# Run as `bash run.sh` on the host that serves it; the settings below are environment variables.
#
# WHY A CONTAINER OF ITS OWN, and not inside EMS: the assistant talks to it directly over the
# OpenAI API, which is what every model service speaks — so a hosted
# provider is a change of CFG_LLM_URL, not of code — and llama.cpp already does what EMS was doing
# around it: the chat template, tool calls as structured `tool_calls`, and the cache of what it last
# read, reusing every leading token a new request shares with it. It stays loaded: a server woken
# from sleep reads the model file again, which a crawl has pushed out of the page cache by then. EMS
# reads the card's free memory for its own models, so it sees this.
#
# HOW MUCH OF THE CARD: as many layers as leave EMS its share, LLM_CARD_RESERVE_MB. A host sets it to
# EMS's own EMS_CARD_SHARE_MB, the most EMS holds there, so neither loads into the other's part
# whichever starts first. llama.cpp fits the layers itself (`-ngl auto --fit`), to what is free less
# a margin, so the margin is that share less what is in use when it starts. It stops about 0.5 GB
# short of what it is given. On a 16 GB card every layer fits; on 12 GB some; on 8 GB none, and it
# runs on the CPU. The same weights wherever they sit, so the answers are the same, only slower. The margin is
# measured when this script runs: if something else holds more than EMS's share then (a GPU
# self-test, say), the model gets fewer layers until its next start. A card that fills up during
# the load fails it; the container restarts until it loads, however many tries that takes. Each of
# those restarts, like any `podman start` of the container, keeps the margin and refits against
# the card as it is by then, so on a shared card only a rerun of this script restores EMS's share.
#
# THE TEMPLATE is Qwen3.5's own with one change (templates/qwen35-stable-history.jinja): every
# assistant turn keeps the empty think block it was written with. The original drops it from turns
# before the latest question, which re-renders the previous round differently once a new question
# arrives and throws that much of the cache away. Thinking is off server-side
# (--chat-template-kwargs), so requests carry only standard fields.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LLM_CONTAINER_NAME="${LLM_CONTAINER_NAME:-llm}"
LLM_PORT="${LLM_PORT:-8190}"
# Pinned by digest: a new llama.cpp build is a new measurement (chat parsing, speed, the cache).
LLM_IMAGE="${LLM_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:bfb3264fc2166e01e2b4f9b537e45d7006d87c75021b911f132ef607f5bbced3}"
# Where the GGUF lives on the host.
LLM_MODELS_PATH="${LLM_MODELS_PATH:-$HOME/services/llm}"
LLM_GGUF_REPO="${LLM_GGUF_REPO:-unsloth/Qwen3.5-4B-GGUF}"
LLM_GGUF_FILE="${LLM_GGUF_FILE:-Qwen3.5-4B-Q8_0.gguf}"
LLM_ALIAS="${LLM_ALIAS:-qwen3.5-4b}"
LLM_TEMPLATE="${LLM_TEMPLATE:-qwen35-stable-history.jinja}"
LLM_CTX="${LLM_CTX:-32768}"
# Host RAM for conversations not on the card, restored when they go on.
LLM_CACHE_RAM_MB="${LLM_CACHE_RAM_MB:-2048}"
# 1: on the card, as much of it as leaves EMS its share. 0: CPU only, for a machine without one.
LLM_GPU="${LLM_GPU:-1}"
LLM_CARD_RESERVE_MB="${LLM_CARD_RESERVE_MB:-8800}"
# The card's size as the model treats it; empty is the whole card. A smaller number rehearses a
# smaller card on a big one, with EMS_CARD_BUDGET_MB set to the same on the EMS side.
LLM_CARD_MB="${LLM_CARD_MB:-}"
# Seconds the server may take to answer after it starts.
LLM_START_WAIT="${LLM_START_WAIT:-900}"

mkdir -p "$LLM_MODELS_PATH"
if [ ! -f "$LLM_MODELS_PATH/$LLM_GGUF_FILE" ]; then
  echo "=== Fetching $LLM_GGUF_REPO/$LLM_GGUF_FILE"
  curl -fL -o "$LLM_MODELS_PATH/$LLM_GGUF_FILE.part" "https://huggingface.co/$LLM_GGUF_REPO/resolve/main/$LLM_GGUF_FILE"
  mv "$LLM_MODELS_PATH/$LLM_GGUF_FILE.part" "$LLM_MODELS_PATH/$LLM_GGUF_FILE"
fi

# Measured with the previous server gone, or its own layers would count against the next one.
podman rm -f "$LLM_CONTAINER_NAME" >/dev/null 2>&1 || true
if [ "$LLM_GPU" = "1" ]; then
  read -r used total < <(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ',')
  share=$((${LLM_CARD_MB:-${total:-0}} - LLM_CARD_RESERVE_MB))
  # llama.cpp fits into what is free less the margin, so the margin is what is free less the share.
  margin=$((${total:-0} - ${used:-0} - share))
  [ "$margin" -lt 1024 ] && margin=1024
fi
if [ "$LLM_GPU" = "1" ] && [ "$share" -gt 1024 ]; then
  gpu=(--device nvidia.com/gpu=all)
  layers=(-ngl auto --fit on --fit-target "$margin")
  echo "=== a share of $share MB of the card, with $used MB of the card in use by others: $margin MB left free beside the model"
else
  # No card, or none left beside EMS's share: the CPU alone, the card not even mapped, so not a
  # buffer of the model's lands on it.
  [ "$LLM_GPU" = "1" ] && echo "=== no room on the card beside EMS's $LLM_CARD_RESERVE_MB MB: on the CPU"
  gpu=()
  layers=(-ngl 0)
fi

echo "=== Starting $LLM_CONTAINER_NAME ($LLM_GGUF_FILE on port $LLM_PORT)"
podman run --replace -d --name "$LLM_CONTAINER_NAME" --restart always --network=host \
  --memory 10g --memory-swap 10g \
  "${gpu[@]}" \
  -v "$LLM_MODELS_PATH:/models:ro" \
  -v "$SCRIPT_DIR/templates:/templates:ro" \
  "$LLM_IMAGE" \
  -m "/models/$LLM_GGUF_FILE" --alias "$LLM_ALIAS" \
  --host 127.0.0.1 --port "$LLM_PORT" \
  "${layers[@]}" -c "$LLM_CTX" -np 1 --cache-ram "$LLM_CACHE_RAM_MB" \
  --jinja --chat-template-file "/templates/$LLM_TEMPLATE" \
  --chat-template-kwargs '{"enable_thinking": false}'

# Ready when it answers: a cold start reads the GGUF from disk, which takes minutes while EMS loads
# its own models beside it. Whoever reruns this on a failure starts
# the load over, so the wait is long enough not to give up on one that is only slow.
deadline=$((SECONDS + LLM_START_WAIT))
while [ $SECONDS -lt $deadline ]; do
  if curl -sf --max-time 5 "http://127.0.0.1:$LLM_PORT/health" >/dev/null; then
    echo "=== $LLM_CONTAINER_NAME is up at http://127.0.0.1:$LLM_PORT/v1"
    exit 0
  fi
  sleep 1
done
echo "$LLM_CONTAINER_NAME did not answer on port $LLM_PORT in ${LLM_START_WAIT}s; podman logs $LLM_CONTAINER_NAME" >&2
exit 1
