# Browser and image model runtime

## Browser bridge

`prolog/rlm_browser.pl` is the deterministic client for Zara's authenticated browser bridge.
The model never receives a callable browser object, browser cookies, or browser profile storage.

The tool pack is loaded as category `browser`:

~~~prolog
rlm_load_tools(Registry, browser, Outcome).
~~~

It advertises:

| tool | effect |
| --- | --- |
| `browser_tabs` | `read` |
| `browser_read` | `read` |
| `browser_elements` | `read` |
| `browser_extract` | `read` |
| `browser_screenshot` | `read` |
| `browser_open` | `network_write` |
| `browser_navigate` | `network_write` |
| `browser_click` | `network_write` |
| `browser_type` | `network_write` |
| `browser_submit` | `network_write` |

Loading the pack grants no capability. Write-class tools still require their explicit tool capability and ordinary authority admission.

The default endpoint is `http://127.0.0.1:8765/v1/rpc`. Authentication uses the execution-time environment reference `ZARA_BROWSER_BRIDGE_TOKEN`. An alternate endpoint can be selected with `PROLOG_RLM_BROWSER_BRIDGE_URL`.

Browser actions use a closed action mapping; model input cannot invent an arbitrary browser RPC method.

## Browser screenshots and vision

`browser_screenshot` returns the active visible tab as a PNG data URL. The existing chain schema already supports multimodal input:

~~~prolog
message{
  role:user,
  content:[
    text("inspect this page"),
    image_url(DataURL, high)
  ]
}
~~~

This deliberately keeps screen capture and model selection as two independent operations.

## Image generation

`prolog/rlm_image.pl` adds a first-class image-output model surface. The canonical direction is `image_generate_execute/3 -> image_generate_async/3 -> image_generate/3`.

Code already executing in an RLM async worker should use `image_generate_execute/3` rather than creating and waiting on a nested Future.

The initial provider adapter is OpenAI-compatible: `openai_image_provider(Endpoint, Credential, Model, Provider)`. Credential is `none` or `env(Name)`. Resolved secrets are not returned in provider terms or outcomes.

The default provider is intentionally explicit and requires `PROLOG_RLM_IMAGE_ENDPOINT`, `PROLOG_RLM_IMAGE_MODEL`, and `PROLOG_RLM_IMAGE_API_KEY`. There is no implicit vendor endpoint.

The `image` tool category exposes `image_generate`. It is classified `network_write` because generation may consume paid inference or create provider-side artifacts.

Supported request fields are `prompt` (required), `n` (1 through 4), `size`, `quality`, `style`, `background`, `output_format`, `response_format`, and `moderation`.

Responses normalize provider image entries containing `url`, `b64_json`, and `revised_prompt` without forcing a particular artifact storage policy.

## Browser posting

Posting to an interactive website is built from the same generic browser primitives: `browser_read -> browser_type -> browser_submit`.

For example, a 4chan post stays inside the user's real browser session rather than introducing a CAPTCHA- or anti-abuse-bypass transport. The final browser mutations remain capability- and authority-gated.
