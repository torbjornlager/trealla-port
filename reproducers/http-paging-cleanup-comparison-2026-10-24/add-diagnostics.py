from pathlib import Path
import json,hashlib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];FILE=ROOT/'http_paging_cleanup_tests.pl'
s=FILE.read_text();before=s;(OUT/'baseline-test.txt').write_text(s)
replacements=[
('    startup_failure,','    page_stage(startup_failure_begin),\n    startup_failure,\n    page_stage(startup_failure_end),'),
('    cached_interruption,','    page_stage(cached_interruption_begin),\n    cached_interruption,\n    page_stage(cached_interruption_end),'),
('    handoff,','    page_stage(handoff_begin),\n    handoff,\n    page_stage(handoff_end),'),
('    eviction_policy,','    page_stage(eviction_policy_begin),\n    eviction_policy,\n    page_stage(eviction_policy_end),'),
('    terminal_answers,','    page_stage(terminal_answers_begin),\n    terminal_answers,\n    page_stage(terminal_answers_end),'),
('    execution_timeout,','    page_stage(execution_timeout_begin),\n    execution_timeout,\n    page_stage(execution_timeout_end),\n    page_stage(final_cleanup_begin),'),
('interruption(Stage) :-\n    self(Parent),','interruption(Stage) :-\n    page_stage(interruption_begin(Stage)),\n    self(Parent),'),
('    (Stage==skip -> Offset=1;Offset=0),','    page_stage(request_enter(Stage)),\n    (Stage==skip -> Offset=1;Offset=0),'),
('      Error,send(Parent,request_error(Error))).','      Error,(page_stage(request_caught(Stage,Error)),\n             send(Parent,request_error(Error)),\n             page_stage(request_error_sent(Stage,Error)))),\n    page_stage(request_returned(Stage)).'),
('blocked(Parent) :- self(Pid),send(Parent,page_started(Pid)),receive({continue -> true}).','blocked(Parent) :- self(Pid),page_stage(producer_started(Pid)),\n    send(Parent,page_started(Pid)),page_stage(producer_wait_begin(Pid)),\n    receive({continue -> true}),page_stage(producer_wait_end(Pid)).'),
('page_expect(Check,Goal) :-\n    ( catch','page_expect(Check,Goal) :-\n    page_stage(check_begin(Check)),\n    ( catch'),
('      throw(page_assertion_failed(Check))\n    ).','      throw(page_assertion_failed(Check))\n    ),\n    page_stage(check_end(Check)).')]
for old,new in replacements:
 assert s.count(old)==1,old
 s=s.replace(old,new)
helper='''
% Test-only timestamped stages. No extra messages, waits or runtime hooks.
page_stage(Stage) :-
    get_time(Time),thread_self(Thread),
    writeq(paging_stage(Time,Thread,Stage)),nl,flush_output.
'''
s+=helper;FILE.write_text(s)
restored=s[:-len(helper)]
for old,new in reversed(replacements):restored=restored.replace(new,old)
assert restored==before
(OUT/'repair-scope.json').write_text(json.dumps({'original_sha256':hashlib.sha256(before.encode()).hexdigest(),'diagnostic_sha256':hashlib.sha256(s.encode()).hexdigest(),'reversing_diagnostic_edits_restores_original':restored==before,'assertions_and_timeouts_unchanged':True},indent=2)+'\n')
