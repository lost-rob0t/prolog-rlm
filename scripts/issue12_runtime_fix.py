from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f'expected one match in {path}: {old[:100]!r}')
    p.write_text(text.replace(old, new, 1))

replace_once(
    'prolog/rlm_graph.pl',
    '            graph_resume/5,\n',
    '            graph_resume/6,\n',
)

replace_once(
    'prolog/rlm_graph.pl',
    'unregister_graph_thread(Token) :-\n    thread_self(Thread),\n    with_mutex(rlm_graph_cancel,\n               retractall(graph_cancel_thread(Token, Thread))).\n',
    'unregister_graph_thread(Token) :-\n    thread_self(Thread),\n    with_mutex(rlm_graph_cancel,\n               (   retract(graph_cancel_thread(Token, Thread))\n               ->  true\n               ;   true\n               )).\n',
)

replace_once(
    'prolog/rlm_graph.pl',
    'execute_loop(Compiled, Config, Token, _, Snapshot0, Outcome) :-\n    Snapshot0.current == end,\n',
    'execute_loop(Compiled, Config, _Token, _, Snapshot0, Outcome) :-\n    Snapshot0.current == end,\n',
)

replace_once(
    'test/rlm_graph_test.pl',
    '          assertion(member(Event, Result.history)),\n          assertion(Event.type == run_completed)\n',
    '          member(Event, Result.history),\n          get_dict(type, Event, run_completed),\n          !\n',
)

print('graph runtime conformance fixes applied')
