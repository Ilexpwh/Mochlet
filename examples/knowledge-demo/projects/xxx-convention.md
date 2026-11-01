---
type: Project Convention
title: XXX report location
description: Example report-output convention with an explicit source.
status: draft
sources:
  - id: fixture-requirements
    resource: ../references/fixture-requirements.md
    title: Example project requirements
x-slime:
  id: fixture-memory-001
  fixture: true
  scope: project
  project_id: example-xxx
  accepted: false
---

# Report output

For this fictional project, generated reports belong in the selected workspace's `Reports` directory.[^fixture-requirements]

This proposed convention must not override the actual project registry, a user's explicit instruction or the runtime's access controls.

[^fixture-requirements]: [Fixture source](../references/fixture-requirements.md).
