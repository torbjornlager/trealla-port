# Separate copied-receive-options observation

An extra new regression fixture copied a helper whose final body contained:

    receive({down(Sup,Sup,_) -> true},[timeout(2),on_timeout(fail)])

A trusted diagnostic of the copied source in the separate v3.14.10 process showed
that fragment as:

    receive({down(...)->true},[timeout(2),on_timeout([]),timeout,2])

The fixture's session then failed with a whitelist error for calling []. This was
not a failure of the constructor's nonbinding checks. The exact source-copy cause
and whether the symptom exists on an unmodified pre-repair source tree were not
investigated in this bounded batch; no engine fault is asserted.

The final additional constructor-copy test uses the same copied constructor and
private child helper, without embedding this unrelated receive-options fragment
in the copied helper. Its controlling parent still uses the same bounded startup
and exact termination checks. No existing suite assertion or timeout was removed
or increased. Both private-source and copied-helper constructor checks pass in
blacklist and whitelist modes. No repair to general source copying was made.
