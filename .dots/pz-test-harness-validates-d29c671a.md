---
title: Test harness validates colors
status: open
priority: 2
issue-type: task
created-at: "2026-02-22T10:26:59.995361+01:00"
---

VScreen frame stores styles per cell but tests only check ASCII text via rowAscii. No test validates colors, styles, ANSI output. Tests miss: thinking traces shown when pi hides them, missing colors, wrong border colors. Fix: add style-aware assertions (expectCellFg, expectCellStyle) and parity tests that check colors
