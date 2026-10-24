# llm

The language model [EiN](https://github.com/einhq)'s assistant talks to: llama.cpp's server,
speaking the OpenAI chat API, in a container of its own on the graphics card. The assistant needs
nothing more than that API, so a hosted provider can stand in for it.

`run.sh` explains the choices: why a container of its own, the pinned image, the model, and the
chat template in `templates/`.

## Running it

```bash
bash run.sh
```

fetches the model on first use, starts the server on the host's network and waits until it
answers at `http://127.0.0.1:8190/v1`, which EiN takes as `CFG_LLM_URL`. The card reaches the
container through CDI, which EMS's README sets up under "A GPU host".

| Variable              | Default                   | What it sets                                                  |
| --------------------- | ------------------------- | ------------------------------------------------------------- |
| `LLM_PORT`            | `8190`                    | the port, on 127.0.0.1                                        |
| `LLM_MODELS_PATH`     | `~/services/llm`          | where the model file is kept                                  |
| `LLM_GGUF_REPO`       | `unsloth/Qwen3.5-4B-GGUF` | the Hugging Face repository the model comes from              |
| `LLM_GGUF_FILE`       | `Qwen3.5-4B-Q8_0.gguf`    | the model file                                                |
| `LLM_CTX`             | `32768`                   | the context, in tokens                                        |
| `LLM_GPU`             | `1`                       | `0` runs it on the processor alone                            |
| `LLM_CARD_RESERVE_MB` | `8800`                    | how much of the card it leaves free, for EMS on the same card |
| `LLM_CONTAINER_NAME`  | `llm`                     | the container's name                                          |

On a card shared with EMS, set `LLM_CARD_RESERVE_MB` to EMS's own share (`EMS_CARD_SHARE_MB`) plus
a little: the model takes as many layers as fit in the rest, and runs the others on the processor.
