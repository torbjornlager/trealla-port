% Metadata inspection must not run source initialization or application code.
:- initialization(throw(metadata_ran_initialization)).
discovery_unstarted(visible).
