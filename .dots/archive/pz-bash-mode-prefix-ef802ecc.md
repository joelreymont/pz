---
title: Bash mode (! prefix in editor)
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T09:43:24.227520+01:00\""
closed-at: "2026-02-22T10:15:29.873655+01:00"
close-reason: "done: parseBashCmd + runBashMode in runtime.zig, !cmd saves to session, !!cmd excludes, transcript shows tool_call/tool_result blocks"
---

Pi supports !command (execute+include in context) and !!command (execute, exclude from context). Editor border changes color in bash mode. Need: detect ! prefix in editor submit, route to bash tool directly bypassing LLM, stream output to transcript, track in session. Ref: pi interactive-mode.ts:1981-1995
