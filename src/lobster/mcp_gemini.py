"""Gemini image generation MCP tools for image-gen lobsters."""

import base64
import logging
import os

from claude_agent_sdk import create_sdk_mcp_server, tool

logger = logging.getLogger("lobster.mcp_gemini")

_genai = None


def _get_client():
    """Lazy-init the google.generativeai client."""
    global _genai
    if _genai is None:
        import google.generativeai as genai

        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            raise RuntimeError("GEMINI_API_KEY environment variable is required")
        genai.configure(api_key=api_key)
        _genai = genai
    return _genai


@tool("generate_image", "Generate an image using Gemini Imagen API", {
    "prompt": str,
    "aspect_ratio": str,
    "num_images": int,
})
async def generate_image(args: dict) -> dict:
    """Generate images via Gemini Imagen API. Returns base64-encoded PNGs."""
    prompt = args["prompt"]
    aspect_ratio = args.get("aspect_ratio", "1:1")
    num_images = args.get("num_images", 1)

    if num_images < 1 or num_images > 4:
        return {"content": [{"type": "text", "text": "Error: num_images must be 1-4"}]}

    try:
        genai = _get_client()
        model = genai.ImageGenerationModel("imagen-3.0-generate-002")

        response = model.generate_images(
            prompt=prompt,
            number_of_images=num_images,
            aspect_ratio=aspect_ratio,
            safety_filter_level="block_only_high",
        )

        results = []
        for i, image in enumerate(response.images):
            b64 = base64.b64encode(image._image_bytes).decode("utf-8")
            results.append({"index": i, "base64_png": b64, "size_bytes": len(image._image_bytes)})

        return {"content": [{"type": "text", "text": f"Generated {len(results)} image(s). Use the base64_png field to save them."}],
                "images": results}

    except Exception as e:
        logger.error("Gemini image generation failed: %s", e)
        return {"content": [{"type": "text", "text": f"Error generating image: {e}"}]}


@tool("save_generated_image", "Decode a base64 PNG and save it to a file path", {
    "base64_png": str,
    "output_path": str,
})
async def save_generated_image(args: dict) -> dict:
    """Decode base64 PNG data and write to disk."""
    b64 = args["base64_png"]
    output_path = args["output_path"]

    try:
        data = base64.b64decode(b64)
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, "wb") as f:
            f.write(data)
        logger.info("Saved image to %s (%d bytes)", output_path, len(data))
        return {"content": [{"type": "text", "text": f"Saved image to {output_path} ({len(data)} bytes)"}]}
    except Exception as e:
        logger.error("Failed to save image to %s: %s", output_path, e)
        return {"content": [{"type": "text", "text": f"Error saving image: {e}"}]}


@tool("list_imagen_models", "List available Gemini image generation models", {})
async def list_imagen_models(args: dict) -> dict:
    """List available Imagen models."""
    try:
        genai = _get_client()
        models = [m.name for m in genai.list_models() if "imagen" in m.name.lower()]
        return {"content": [{"type": "text", "text": f"Available Imagen models: {', '.join(models) or 'none found'}"}]}
    except Exception as e:
        return {"content": [{"type": "text", "text": f"Error listing models: {e}"}]}


# MCP server instance
gemini_mcp = create_sdk_mcp_server(
    name="gemini-imagen",
    version="1.0.0",
    tools=[generate_image, save_generated_image, list_imagen_models],
)
