# Explicit visual file summaries

Files → Include image previews in this summary opts the next summary into sending selected image previews to OpenRouter and the selected analysis model. The default remains extracted text only. The model catalog is refreshed for the request; image input and text output are required. Unsupported combinations fail without sending image content or selecting another model/provider.

The request contains source-ID-labelled images alongside the existing evidence JSON. Replies use the same citation validation as text summaries. Visual observations can still be wrong; citation validity is not factual verification. OCR-only coding attachments and saved memory remain text, and PDF diagrams/scans are not rendered by this feature.

Local preparation verifies the original ingestion SHA-256, rejects changed files/symlinks, reads at most 5 MB, and validates image headers before decoding. Both ingestion OCR and preparation reject dimensions over 8192 pixels per edge or 40 megapixels. JPEG previews are at most 2048 pixels on their longest edge, quality 0.85, with orientation applied and original EXIF/GPS metadata omitted. The JPEG encoder may add basic color-space/dimension metadata. Only the first image frame/page is sent. Source files remain unchanged.

A request contains at most six files, six distinct image IDs, 4 MB per prepared image and 12 MB of image bytes total, before base64 encoding. PNG, JPEG, HEIC, TIFF and WebP use the local ImageIO decoder; actual format support depends on macOS. Valid images without recognized OCR text remain attachable with an explicit no-text placeholder. Selected IDs and the model are captured when summary starts, and changed selections suppress obsolete results.

## Evidence — 2026-11-01

Four core fixtures cover no-text ingestion, revision/symlink rejection, original metadata removal, source-ID wire mapping, provider fallback suppression, unsupported model capabilities, model responses and oversized image headers before OCR. They use synthetic pixels and local HTTP fixtures; no live model quality claim is made.

The full check passes 112 reported tests (109 fixture declarations and three opt-in live skips), native Debug build and runtime fixtures. It also includes a command-process fix prompted by load testing: blocking pipe reads now run on utility dispatch threads, leaving Swift's cooperative executor available for deadlines. A 24-command timeout regression passed in about 0.2 seconds instead of waiting for the eight-second child processes. Completion also checks an absolute monotonic deadline.

Primary API reference: [OpenRouter image inputs](https://openrouter.ai/docs/guides/overview/multimodal/image-understanding), [provider fallback selection](https://openrouter.ai/docs/guides/routing/provider-selection). Live provider quality, multilingual visual text and larger image-format matrices remain validation work requiring a user-selected model/key.

Native walkthrough fed Mochlet’s original icon without OCR text, observed chewing finish, inspected the no-text placeholder, enabled the image-preview disclosure, and verified Summarize stays disabled without a configured key/model. [Native evidence](evidence/native-image-analysis.png). This exercised local ingestion and controls, not a live vision request.
