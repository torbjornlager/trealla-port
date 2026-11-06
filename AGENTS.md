# Shared runtime behavior

Appendix B is the language contract. Use native SWI's solution as the design
reference for shared behavior. Before departing from it, identify the concrete
Trealla engine constraint, keep the adaptation small, and keep implementation
machinery inside the runtime boundary. Do not export runtime guards as user source.

Add shared behavioral regressions and run the same cases against both native
implementations. Existing shared selections live in the sibling
`trinity-conformance` repository. A passing SWI result does not override the
language contract or excuse a SWI bug.
