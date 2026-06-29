# Leythers.com Engineering Spec Pack

This folder contains implementation-ready docs optimized for LLM ingestion.

## Purpose

- Convert the provided high-level concept into a concrete build specification.
- Resolve naming and boundary inconsistencies against this repository.
- Provide a deterministic implementation plan with acceptance criteria.

## Current Repository Reality

- OTP app: `:leythers_com`
- Root module namespace: `LeythersCom`
- Existing repository context does not yet include domain contexts/migrations for the planned product.

## Document Index

1. `01_product_scope.md`: Product goals, constraints, and non-goals.
2. `02_architecture.md`: Context boundaries, supervision, and system flows.
3. `03_data_model.md`: Database design, constraints, and schema conventions.
4. `04_pipelines.md`: Event-driven ingestion pipeline and fast-track manual flow.
5. `05_implementation_plan.md`: Sequenced work plan with milestones.
6. `06_acceptance_criteria.md`: Definition of done per phase.
7. `context/project_context.md`: High-signal compact project context.
8. `context/implementation_context.md`: End-to-end implementation brief/prompt.

## How To Use This Pack With LLMs

- Start with `context/project_context.md` for compact grounding.
- Use `05_implementation_plan.md` to drive execution order.
- Use `06_acceptance_criteria.md` as review checklist before merge.
- Use `context/implementation_context.md` when prompting an implementation agent.
