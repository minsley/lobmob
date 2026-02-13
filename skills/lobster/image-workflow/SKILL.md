---
name: image-workflow
description: Structured workflow for generating, evaluating, and storing images via Gemini Imagen API
---

# Image Workflow

Use this skill when you've been assigned an image generation task. Follow this structured process to produce high-quality results.

## 1. Read the Brief

1. Pull the vault: `cd /opt/vault && git pull origin main --rebase`
2. Read the task file at `010-tasks/active/<task-id>.md`
3. Extract:
   - **Subject**: What to generate
   - **Style**: Art style, mood, aesthetic
   - **Dimensions**: Aspect ratio requirements
   - **Quantity**: How many final images
   - **Criteria**: Quality standards, must-haves, must-avoids

## 2. Craft Initial Prompts

Write 2-3 prompt variants that approach the subject differently:
- Vary style keywords (photorealistic vs. illustrated vs. abstract)
- Vary composition (close-up vs. wide shot vs. bird's eye)
- Keep core subject consistent across variants

## 3. Generate Initial Set

Use `generate_image` to produce initial candidates:
```
generate_image(prompt="<detailed prompt>", aspect_ratio="1:1", num_images=2)
```

Generate from each prompt variant to build a diverse candidate pool.

## 4. Evaluate Against Criteria

For each generated image, assess:
- Does it match the requested subject?
- Does the style match requirements?
- Is the composition effective?
- Are there artifacts or quality issues?
- Does it meet the specific acceptance criteria from the task?

Note: You cannot view the images directly. Evaluate based on the generation parameters and any metadata returned. If the task has specific visual criteria, note them for the task requester to verify.

## 5. Refine and Iterate

Based on evaluation:
- Adjust prompts to fix issues (e.g., add "no text" if unwanted text appears)
- Try different aspect ratios if composition isn't working
- Generate additional variants of the best-performing prompts
- Aim for 2-3 rounds maximum to avoid excessive API usage

## 6. Save Final Results

Save selected images to the vault:
```
save_generated_image(base64_png="<data>", output_path="/opt/vault/030-knowledge/assets/<task-id>/image-01.png")
```

Create a gallery page documenting each image with its generation prompt and parameters.

## 7. Submit Results

Update the task file with:
- `status: completed`
- Result section with number of images generated, prompts used, and gallery link
- Any notes about quality or limitations

Create a vault PR with all generated assets and the gallery page.
