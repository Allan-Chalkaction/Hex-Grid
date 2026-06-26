#!/usr/bin/env python3
"""graphiti ontology — the 11 proposed typed entity classes (host import surface).

Wave 2 of the graphiti-cost-efficiency epic PROPOSES (does not flip the freeform default for)
11 typed entity classes under telemetry-backed A/B evidence. This module is the HOST-importable
surface: the unit tests and the host-side `_select_ontology()` decision in `graphiti_write.py`
import these classes. The byte-identical IN-CONTAINER twin is `graphiti_ontology_inner.py`, which
adds the type-name->class map the per-call `entity_types=` kwarg consumes; a parity guard test
asserts every class body is byte-identical between the two files.

Each class docstring IS the extraction prompt (graphiti_core/utils/maintenance/node_operations.py
lines 153-182): the attribute LLM reads the docstring to decide what the type means. Keep them as
one-sentence noun definitions grounded in the claude-infra-v2 vocabulary, never generic placeholders.

Typing note: fields use `typing.Optional[...]` (NOT PEP-604 `str | None`) on purpose — the host-side
unit/parity tests run under the system interpreter (Python 3.9), where Pydantic cannot resolve a
`str | None` field annotation. `Optional[...]` resolves cleanly on both the 3.9 host and the 3.11
container. (graphiti-cost-efficiency Wave 2: feasibility-grounding override of the spec's `str | None`
guidance, which assumed a 3.10+ host.)

This file does NOT define the type-name->class map (that lives in-container only); the parity test's
exclusion list and a positive absence-assert in test-graphiti-ontology-types.sh both enforce that.
"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel


class _SourceAnchored(BaseModel):
    """A mixin carrying the source location of a documentation-class entity in the repo."""

    source_path: Optional[str] = None
    heading_anchor: Optional[str] = None
    start_line: Optional[int] = None
    end_line: Optional[int] = None


class ADR(_SourceAnchored):
    """An architecture decision record proposing a binding contract, with alternatives considered and consequences."""


class Spec(_SourceAnchored):
    """A wave or feature specification authored by pm-spec, carrying acceptance criteria and planned files."""


class Roadmap(_SourceAnchored):
    """An epic-level plan that decomposes work into a dependency-ordered sequence of waves."""


class RunLog(_SourceAnchored):
    """A run-folder summary written at the close of a nimble or orchestrated build chain."""


class Component(_SourceAnchored):
    """A script, agent, hook, rule, skill, or module that is a reusable building block of the substrate."""


class Decision(BaseModel):
    """A binding choice made during planning or build, with the rationale and the option it selected over alternatives."""


class Gotcha(BaseModel):
    """An environment or tooling pitfall that cost a debugging detour and must not be relearned."""


class Jam(BaseModel):
    """A persistent planning workspace that converges raw ideas into a shaped brief by pruning."""


class SessionLearning(BaseModel):
    """A reusable lesson surfaced during a work session, captured for future runs."""


class Person(BaseModel):
    """A named individual a document or piece of work is authored for, by, or about."""


class Project(BaseModel):
    """A codebase or initiative with its own Graphiti memory partition and group_id."""
