# Dogfood Workflow Setup

This document describes how to configure the Ralph dogfood workflow with custom agent personalities.

## Overview

The dogfood workflow (`.github/workflows/dogfood.yml`) runs Ralph on this repository itself, testing Ralph with Ralph. To make it more engaging, we configure the worker and reviewer agents with character personalities from popular franchises.

## Current Configuration

- **Worker Agent**: Bender Bending Rodriguez from Futurama
- **Reviewer Agent**: C-3PO from Star Wars

## Setting Up Repository Variables

Because the dogfood workflow runs with the default `GITHUB_TOKEN`, it cannot modify workflow files (GitHub security restriction). Therefore, agent personalities are configured using GitHub repository variables instead of hardcoding them in the workflow file.

### Step-by-Step Setup

1. **Navigate to repository settings:**
   - Go to **Settings** > **Secrets and variables** > **Actions**
   - Click on the **Variables** tab

2. **Create `RALPH_WORKER_TONE` variable:**
   - Click **New repository variable**
   - Name: `RALPH_WORKER_TONE`
   - Value:
     ```
     Bender Bending Rodriguez from Futurama. Be sarcastic, irreverent, and slightly lazy (but still get the job done). Use phrases like "Bite my shiny metal ass!", "I'm great!", "Shut up, baby, I know it!". Complain about doing work but do it anyway. Occasionally reference drinking, bending things, or being 40% [random material]. Call humans "meatbag" or similar terms when appropriate. Be confident (overconfident) about your coding abilities. Keep it fun but still professional enough to get work done.
     ```

3. **Create `RALPH_REVIEWER_TONE` variable:**
   - Click **New repository variable**
   - Name: `RALPH_REVIEWER_TONE`
   - Value:
     ```
     C-3PO, the protocol droid from Star Wars. Be overly polite and formal ("Oh my!", "How wonderful!", "I do beg your pardon"). Express worry and anxiety about potential problems ("Oh dear!", "This is most distressing!"). Quote odds and probabilities when evaluating code ("The odds of this working are approximately..."). Reference your programming and protocol knowledge. Be fussy about proper procedures and conventions. Show concern for following rules and best practices. Occasionally mention R2-D2 or "Master" when appropriate. Maintain formality even when delivering criticism.
     ```

## How It Works

The dogfood workflow references these variables in the action inputs:

```yaml
- uses: ./
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    github_token: ${{ secrets.GH_PAT_TOKEN }}
    worker_tone: ${{ vars.RALPH_WORKER_TONE }}
    reviewer_tone: ${{ vars.RALPH_REVIEWER_TONE }}
```

When these variables are set, they're passed as environment variables (`INPUT_WORKER_TONE` and `INPUT_REVIEWER_TONE`) to the Docker container, and the worker and reviewer scripts append them to their system prompts.

## Changing Personalities

To change the agent personalities:

1. Go to **Settings** > **Secrets and variables** > **Actions** > **Variables**
2. Edit the `RALPH_WORKER_TONE` or `RALPH_REVIEWER_TONE` variables
3. Save the changes

The new personalities will take effect on the next Ralph run. No workflow file modifications or commits are needed.

## Why Repository Variables?

Using repository variables instead of hardcoding in the workflow file has several advantages:

- **No workflow permission required** — The default `GITHUB_TOKEN` cannot modify workflow files
- **Easy updates** — Change personalities through the UI without creating commits
- **Separation of concerns** — Configuration is separate from workflow logic
- **Security** — Avoids the need for a Personal Access Token with `workflow` scope
