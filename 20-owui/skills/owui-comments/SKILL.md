---
name: owui-comments
description: >
  Read and write review comments attached to Open WebUI notes, chats, knowledge bases, models, prompts,
  skills and tools. Use when the user asks to review comments on a note or leave feedback on a resource.
---

# Comments

`resource_type` is one of `note`, `chat`, `knowledge`, `model`, `prompt`, `skill`, `tool`.

```bash
# Comment threads on a note.
owui-api GET '/api/v1/comments/?resource_type=note&resource_id=<note-id>' | jq -r '.items[] | [.id, .user.name, .content] | @tsv'
# Replies in one thread.
owui-api GET /api/v1/comments/<comment-id>/replies | jq -r '.items[] | [.user.name, .content] | @tsv'
# Add a comment (posted as the current user, visible to everyone who can see the note).
owui-api POST /api/v1/comments/ '{"resource_type":"note","resource_id":"<note-id>","content":"..."}'
# Reply in a thread.
owui-api POST /api/v1/comments/<comment-id>/replies '{"content":"..."}'
```

- Posting a comment notifies other users. Show the text to the user and get approval before posting.
- Do not edit or delete comments written by other users.

Full endpoint list: `references/api.md` (generated from the Open WebUI OpenAPI schema).
General rules and authentication: the `open-webui` skill.
