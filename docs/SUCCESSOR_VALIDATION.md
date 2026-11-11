# Successor validation on native Trealla

Appendix B requires succ/2 to relate non-negative integers. Native SWI supplies
the reference behavior. On the supported Trealla 3.14.20 engine, supplied floats
can produce an instantiation error or failure instead of the required integer
type error. The port therefore validates both supplied arguments before choosing
a direction and shares that relation across node, actor and private-source calls.
Trealla builtin metadata can also bypass module imports in source-free owner
queries, so runtime dispatch explicitly selects the relation for succ/2 and
literal call(succ,...). It does not bind unknown closures. The installed engine
and its libraries are unchanged.

The helper remains inside the runtime boundary. Copied source retains public
succ/2 calls, without runtime guards or module-qualified implementation machinery.
The focused unit group checks direct calls, admitted higher-order calls, receive
guards and bodies, private predicates, copied source, integer/zero/domain cases,
and both-variable errors in blacklist, whitelist and owner sandbox-off modes.

This extraction excludes the large prerequisite library harness. Its maplist
callback case depends on the separate pending whitelist library-admission work;
that case remains with the library batch. It is not counted as passing here.
