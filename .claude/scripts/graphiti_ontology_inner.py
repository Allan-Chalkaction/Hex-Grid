#!/usr/bin/env python3
"""graphiti ontology — the 11 proposed typed entity classes (IN-CONTAINER source).

This is the byte-identical (per class body) twin of `graphiti_ontology_types.py`. It is NOT
imported on the host: `graphiti_write.py` reads this file's TEXT at module load and prepends it
to the in-container `_INNER` body before `docker exec`, so the mcp container compiles these
classes from source on each write (the cross-repo in-container import seam, architect D2 Option b).

The class bodies below MUST stay byte-identical to `graphiti_ontology_types.py`
(test-graphiti-ontology-source-parity.sh enforces this via AST). The ONLY differences this file
carries are excluded from the parity check: the module docstring, the imports, and the
`ENTITY_TYPES` map at the bottom (the type-name->class dict the per-call `entity_types=` kwarg
consumes — in-container only).

Typing note: fields use `typing.Optional[...]` (NOT PEP-604 `str | None`) so the same source
compiles on the 3.9 host (parity/unit tests) and the 3.11 container alike.
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


# IN-CONTAINER ONLY (excluded from the source-parity check): the type-name -> class map the
# per-call entity_types= kwarg on add_episode consumes. The host twin does NOT define this.
ENTITY_TYPES = {
    "ADR": ADR,
    "Spec": Spec,
    "Decision": Decision,
    "Gotcha": Gotcha,
    "Roadmap": Roadmap,
    "Jam": Jam,
    "SessionLearning": SessionLearning,
    "RunLog": RunLog,
    "Component": Component,
    "Person": Person,
    "Project": Project,
}
