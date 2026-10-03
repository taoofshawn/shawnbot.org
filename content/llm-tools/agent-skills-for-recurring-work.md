---
title: "Agent skills for recurring work"
date: 2026-02-14
summary: "Encoding repeatable workflows as agent skills so agents stop rediscovering them."
tags: [llm, agents, skills]
---

## The idea

Anything done more than twice by an agent is a skill: a short markdown file
that tells the agent the workflow, the conventions, and the verification
steps.

## What belongs in a skill

- When to use it (trigger conditions)
- Exact commands and file paths
- What "done" looks like, in verifiable terms

## What does not

- Anything speculative — skills accrue complexity the same way code does.
