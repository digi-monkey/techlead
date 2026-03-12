# Techlead Iteration CLI

A lightweight CLI for iterative code improvement with OpenCode.

## What This Repo Contains

- iterate.zig: CLI entrypoint with two commands: init and run
- program.md: Prompt template consumed by the CLI
- demo-topk/: Minimal JavaScript demo project for testing the workflow

## Prerequisites

1. Zig 0.15+
2. opencode CLI installed and available in PATH
3. A running OpenCode server
4. A Git repository for the target project

## Start OpenCode Server

Example:

    opencode serve

If your server is already running, keep its URL, for example:

    http://127.0.0.1:54839

## CLI Commands

Initialize a project (creates techlead.json and program.md in current directory):

    zig run /path/to/iterate.zig -- init "your goal description"

Force overwrite existing techlead.json and program.md:

    zig run /path/to/iterate.zig -- init "your goal description" --force

Run iterations using techlead.json:

    zig run /path/to/iterate.zig -- run

## Typical Local Usage In This Repo

From repository root:

    zig run iterate.zig -- init "Optimize code while keeping tests green" --force

Edit techlead.json and set your OpenCode server URL:

    {
      "opencode_url": "http://127.0.0.1:54839"
    }

Then run:

    zig run iterate.zig -- run

## Recommended Safe Test Flow (TMP Copy)

To avoid polluting your source project, copy demo-topk to /tmp and run there.

1. Create tmp copy and initialize git:

    TMP_DEMO_DIR=$(mktemp -d /tmp/techlead-demo-topk.XXXXXX)
    cp -R demo-topk "$TMP_DEMO_DIR/project"
    cd "$TMP_DEMO_DIR/project"
    git init
    git add .
    git commit -m "baseline demo"

2. Initialize the tmp project with this CLI:

    zig run /Users/retric/Desktop/autocode/iterate.zig -- init "Optimize findTopKFrequent and reduce benchmark latency" --force

3. Point techlead.json to your server URL:

    OPENCODE_SERVER_URL="YOUR_SERVER_URL"
    perl -0pi -e 's#"opencode_url"\s*:\s*"[^"]+"#"opencode_url": "'"$OPENCODE_SERVER_URL"'"#' techlead.json

4. Optionally reduce iterations for quick verification:

    perl -0pi -e 's#"iterations"\s*:\s*\d+#"iterations": 1#' techlead.json

5. Run iteration:

    zig run /Users/retric/Desktop/autocode/iterate.zig -- run

## Demo Project Commands

From demo-topk:

    npm test
    npm run bench

## Notes

- The CLI attaches to OpenCode with --attach and pins remote working directory with --dir.
- This helps avoid cross-project context leakage when using a shared server.
- Iteration logs are written to .iteration-logs in the target project.
