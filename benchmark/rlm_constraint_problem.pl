:- encoding(utf8).

:- module(rlm_constraint_problem,
          [ constraint_problem_prompt/1,
            constraint_guidance/2,
            constraint_known_solution/1,
            constraint_solution_count/1,
            constraint_verify_assignment/2,
            constraint_verify_text/2,
            constraint_verification_status/4
          ]).

/** <module> Deterministic hard CSP fixture and trusted benchmark verifier

The live RLM benchmark uses this module as a host-owned oracle. Model output is
JSON data only; it never becomes executable Prolog. The same constraints define
the deterministic fixture solver and the independent verification report.
*/

:- use_module(library(clpfd)).
:- use_module(library(http/json)).
:- use_module(library(lists)).

constraint_problem_prompt(Prompt) :-
    Prompt =
"Solve this relay-allocation constraint problem. There are ten tasks: alpha, beta, gamma, delta, epsilon, zeta, eta, theta, iota, kappa. Each task must receive exactly one SLOT, NODE, and PHASE. Each attribute is a permutation of the integers 1..10: every number is used exactly once for slots, once for nodes, and once for phases.\n\
\n\
Slot constraints:\n\
S1 alpha + beta = 9.\n\
S2 gamma - delta = 6.\n\
S3 epsilon + zeta = 10.\n\
S4 eta + iota = 9.\n\
S5 theta - kappa = 3.\n\
S6 alpha - kappa = 2.\n\
S7 epsilon - theta = 1.\n\
S8 eta - delta = 2.\n\
S9 iota - beta = 1.\n\
S10 kappa - zeta = 4.\n\
S11 gamma - alpha = 3.\n\
S12 theta - eta = 2.\n\
\n\
Node constraints, where references on the right are SLOT values unless explicitly marked NODE:\n\
N1 node(alpha) = slot(iota).\n\
N2 node(beta) = slot(epsilon).\n\
N3 node(gamma) = slot(zeta).\n\
N4 node(delta) = slot(gamma).\n\
N5 node(epsilon) = slot(delta).\n\
N6 node(zeta) = slot(alpha).\n\
N7 node(eta) = slot(beta).\n\
N8 node(theta) = slot(eta).\n\
N9 node(iota) = slot(theta).\n\
N10 node(kappa) = slot(kappa).\n\
\n\
Phase constraints:\n\
P1 phase(alpha) = slot(theta).\n\
P2 phase(beta) = node(epsilon).\n\
P3 phase(gamma) = slot(eta).\n\
P4 phase(delta) = node(eta).\n\
P5 phase(epsilon) = node(delta).\n\
P6 phase(zeta) = slot(kappa).\n\
P7 phase(eta) = node(gamma).\n\
P8 phase(theta) = node(beta).\n\
P9 phase(iota) = node(zeta).\n\
P10 phase(kappa) = slot(iota).\n\
\n\
Global checks:\n\
G1 exactly two of slot(alpha), slot(delta), slot(eta), slot(iota) are even.\n\
G2 phase(beta)+phase(delta)+phase(zeta)+phase(kappa)=14.\n\
G3 node(epsilon)+node(theta)=10.\n\
G4 slot(gamma)+slot(epsilon)=19.\n\
G5 (slot(alpha)>slot(eta)) iff (phase(theta)>node(iota)).\n\
G6 (slot(epsilon)>slot(theta)) iff (phase(epsilon)>node(beta)).\n\
G7 node(alpha)<slot(delta).\n\
G8 phase(gamma)+phase(eta)=7.\n\
G9 node(delta)-node(gamma)=9.\n\
\n\
Return ONLY one JSON object with exactly this shape and all ten rows:\n\
{\"assignments\":[{\"task\":\"alpha\",\"slot\":1,\"node\":1,\"phase\":1}, ...]}\n\
Do not omit tasks. Do not add prose.".

constraint_guidance(Depth, Guidance) :-
    format(string(Guidance),
           "Benchmark-only planning hint: solve the all-different slot system first, propagate node equalities second, then phase equalities, and perform the global checks last. The final model response must be only the requested JSON assignment. Recursion budget is depth ~d; when recursion is available, use it for independent checking/decomposition rather than echoing the same prompt.",
           [Depth]).

constraint_known_solution(
    _{assignments:[
        _{task:alpha,   slot:7,  node:3,  phase:8},
        _{task:beta,    slot:2,  node:9,  phase:4},
        _{task:gamma,   slot:10, node:1,  phase:6},
        _{task:delta,   slot:4,  node:10, phase:2},
        _{task:epsilon, slot:9,  node:4,  phase:10},
        _{task:zeta,    slot:1,  node:7,  phase:5},
        _{task:eta,     slot:6,  node:2,  phase:1},
        _{task:theta,   slot:8,  node:6,  phase:9},
        _{task:iota,    slot:3,  node:8,  phase:7},
        _{task:kappa,   slot:5,  node:5,  phase:3}
    ]}).

constraint_solution_count(Count) :-
    findall(Assignment, constraint_solution(Assignment), Solutions),
    length(Solutions, Count).

constraint_solution(Assignment) :-
    length(Slots, 10),
    length(Nodes, 10),
    length(Phases, 10),
    Slots ins 1..10,
    Nodes ins 1..10,
    Phases ins 1..10,
    all_distinct(Slots),
    all_distinct(Nodes),
    all_distinct(Phases),
    apply_slot_constraints(Slots),
    apply_node_constraints(Slots, Nodes),
    apply_phase_constraints(Slots, Nodes, Phases),
    apply_global_constraints(Slots, Nodes, Phases),
    append([Slots, Nodes, Phases], Variables),
    labeling([ffc,bisect], Variables),
    values_assignment(Slots, Nodes, Phases, Assignment).

constraint_verify_text(Text0, Outcome) :-
    catch(( text_string(Text0, Text),
            extract_json_object(Text, Json),
            atom_string(Atom, Json),
            atom_json_dict(Atom, Assignment, [value_string_as(atom)]),
            constraint_verify_assignment(Assignment, Outcome)
          ),
          Exception,
          verification_exception(parse, Exception, Outcome)).

constraint_verify_assignment(Input, Outcome) :-
    catch(verify_assignment(Input, Outcome),
          Exception,
          verification_exception(normalize, Exception, Outcome)).

verify_assignment(Input, ok(Report)) :-
    normalize_assignment(Input, Slots, Nodes, Phases),
    findall(Id,
            ( constraint_id(Id),
              \+ constraint_holds(Id, Slots, Nodes, Phases)
            ),
            Violations),
    (   Violations == []
    ->  Status = passed
    ;   Status = rejected
    ),
    Report = constraint_verification{
                 status:Status,
                 complete:true,
                 unique_fixture:true,
                 violations:Violations,
                 slots:Slots,
                 nodes:Nodes,
                 phases:Phases
             }.

constraint_verification_status(ok(Report), Status, Quality, Details) :-
    !,
    (   Report.status == passed
    ->  Status = pass,
        Quality = 1.0
    ;   Status = fail,
        Quality = 0.0
    ),
    Details = _{verification_status:Report.status,
                solution_complete:Report.complete,
                unique_fixture:Report.unique_fixture,
                violations:Report.violations}.
constraint_verification_status(error(Error), fail, 0.0,
                               _{verification_status:error,
                                 solution_complete:false,
                                 unique_fixture:true,
                                 error:Error}).

normalize_assignment(Input, Slots, Nodes, Phases) :-
    require_exact_keys(Input, [assignments], assignment),
    get_dict(assignments, Input, Rows0),
    require_list(Rows0, assignments),
    length(Rows0, Count),
    (   Count =:= 10
    ->  true
    ;   throw(constraint_shape(row_count(Count, 10)))
    ),
    maplist(normalize_row, Rows0, Rows),
    findall(Task, member(row(Task, _, _, _), Rows), Tasks0),
    sort(Tasks0, UniqueTasks),
    canonical_tasks(Canonical),
    sort(Canonical, CanonicalSorted),
    (   UniqueTasks == CanonicalSorted,
        length(Tasks0, 10)
    ->  true
    ;   throw(constraint_shape(task_set(Tasks0)))
    ),
    maplist(row_for_task(Rows), Canonical, OrderedRows),
    maplist(row_slot, OrderedRows, Slots),
    maplist(row_node, OrderedRows, Nodes),
    maplist(row_phase, OrderedRows, Phases).

normalize_row(Row0, row(Task, Slot, Node, Phase)) :-
    require_exact_keys(Row0, [node,phase,slot,task], assignment_row),
    get_dict(task, Row0, Task0),
    normalize_task(Task0, Task),
    get_dict(slot, Row0, Slot),
    get_dict(node, Row0, Node),
    get_dict(phase, Row0, Phase),
    maplist(require_domain_integer, [Slot, Node, Phase]).

require_exact_keys(Dict, Expected0, Name) :-
    (   is_dict(Dict)
    ->  dict_pairs(Dict, _, Pairs),
        pairs_keys(Pairs, Keys0),
        sort(Keys0, Keys),
        sort(Expected0, Expected),
        ( Keys == Expected
        -> true
        ;  throw(constraint_shape(keys(Name, Keys, Expected)))
        )
    ;   throw(constraint_shape(not_a_dict(Name)))
    ).

pairs_keys([], []).
pairs_keys([Key-_|Pairs], [Key|Keys]) :- pairs_keys(Pairs, Keys).

require_list(Value, _) :- is_list(Value), !.
require_list(_, Name) :- throw(constraint_shape(not_a_list(Name))).

normalize_task(Task, Task) :- atom(Task), valid_task(Task), !.
normalize_task(Task0, Task) :-
    string(Task0),
    atom_string(Task, Task0),
    valid_task(Task),
    !.
normalize_task(Task, _) :- throw(constraint_shape(invalid_task(Task))).

require_domain_integer(Value) :-
    integer(Value),
    between(1, 10, Value),
    !.
require_domain_integer(Value) :-
    throw(constraint_shape(invalid_domain_value(Value))).

row_for_task(Rows, Task, Row) :-
    findall(Candidate,
            member(Candidate, Rows),
            All),
    include(row_has_task(Task), All, Matches),
    (   Matches = [Row]
    ->  true
    ;   throw(constraint_shape(task_multiplicity(Task)))
    ).

row_has_task(Task, row(Task, _, _, _)).
row_slot(row(_, Slot, _, _), Slot).
row_node(row(_, _, Node, _), Node).
row_phase(row(_, _, _, Phase), Phase).

canonical_tasks([alpha,beta,gamma,delta,epsilon,zeta,eta,theta,iota,kappa]).
valid_task(Task) :- canonical_tasks(Tasks), memberchk(Task, Tasks).

task_index(alpha, 1).
task_index(beta, 2).
task_index(gamma, 3).
task_index(delta, 4).
task_index(epsilon, 5).
task_index(zeta, 6).
task_index(eta, 7).
task_index(theta, 8).
task_index(iota, 9).
task_index(kappa, 10).

value_at(Values, Task, Value) :- task_index(Task, Index), nth1(Index, Values, Value).

all_distinct_ground(Values) :- sort(Values, Unique), length(Values, N), length(Unique, N).

even_count(Values, Count) :- include(even_integer, Values, Evens), length(Evens, Count).
even_integer(Value) :- 0 is Value mod 2.

constraint_id(slots_all_distinct).
constraint_id(nodes_all_distinct).
constraint_id(phases_all_distinct).
constraint_id(s1_alpha_beta_sum_9).
constraint_id(s2_gamma_delta_diff_6).
constraint_id(s3_epsilon_zeta_sum_10).
constraint_id(s4_eta_iota_sum_9).
constraint_id(s5_theta_kappa_diff_3).
constraint_id(s6_alpha_kappa_diff_2).
constraint_id(s7_epsilon_theta_diff_1).
constraint_id(s8_eta_delta_diff_2).
constraint_id(s9_iota_beta_diff_1).
constraint_id(s10_kappa_zeta_diff_4).
constraint_id(s11_gamma_alpha_diff_3).
constraint_id(s12_theta_eta_diff_2).
constraint_id(n1_alpha_iota_slot).
constraint_id(n2_beta_epsilon_slot).
constraint_id(n3_gamma_zeta_slot).
constraint_id(n4_delta_gamma_slot).
constraint_id(n5_epsilon_delta_slot).
constraint_id(n6_zeta_alpha_slot).
constraint_id(n7_eta_beta_slot).
constraint_id(n8_theta_eta_slot).
constraint_id(n9_iota_theta_slot).
constraint_id(n10_kappa_kappa_slot).
constraint_id(p1_alpha_theta_slot).
constraint_id(p2_beta_epsilon_node).
constraint_id(p3_gamma_eta_slot).
constraint_id(p4_delta_eta_node).
constraint_id(p5_epsilon_delta_node).
constraint_id(p6_zeta_kappa_slot).
constraint_id(p7_eta_gamma_node).
constraint_id(p8_theta_beta_node).
constraint_id(p9_iota_zeta_node).
constraint_id(p10_kappa_iota_slot).
constraint_id(g1_two_selected_slots_even).
constraint_id(g2_phase_subset_sum_14).
constraint_id(g3_node_epsilon_theta_sum_10).
constraint_id(g4_slot_gamma_epsilon_sum_19).
constraint_id(g5_biconditional_alpha_eta_theta_iota).
constraint_id(g6_biconditional_epsilon_theta_epsilon_beta).
constraint_id(g7_node_alpha_lt_slot_delta).
constraint_id(g8_phase_gamma_eta_sum_7).
constraint_id(g9_node_delta_gamma_diff_9).

constraint_holds(slots_all_distinct, S, _, _) :- all_distinct_ground(S).
constraint_holds(nodes_all_distinct, _, N, _) :- all_distinct_ground(N).
constraint_holds(phases_all_distinct, _, _, P) :- all_distinct_ground(P).
constraint_holds(s1_alpha_beta_sum_9, S, _, _) :- value_at(S,alpha,A), value_at(S,beta,B), A+B =:= 9.
constraint_holds(s2_gamma_delta_diff_6, S, _, _) :- value_at(S,gamma,A), value_at(S,delta,B), A-B =:= 6.
constraint_holds(s3_epsilon_zeta_sum_10, S, _, _) :- value_at(S,epsilon,A), value_at(S,zeta,B), A+B =:= 10.
constraint_holds(s4_eta_iota_sum_9, S, _, _) :- value_at(S,eta,A), value_at(S,iota,B), A+B =:= 9.
constraint_holds(s5_theta_kappa_diff_3, S, _, _) :- value_at(S,theta,A), value_at(S,kappa,B), A-B =:= 3.
constraint_holds(s6_alpha_kappa_diff_2, S, _, _) :- value_at(S,alpha,A), value_at(S,kappa,B), A-B =:= 2.
constraint_holds(s7_epsilon_theta_diff_1, S, _, _) :- value_at(S,epsilon,A), value_at(S,theta,B), A-B =:= 1.
constraint_holds(s8_eta_delta_diff_2, S, _, _) :- value_at(S,eta,A), value_at(S,delta,B), A-B =:= 2.
constraint_holds(s9_iota_beta_diff_1, S, _, _) :- value_at(S,iota,A), value_at(S,beta,B), A-B =:= 1.
constraint_holds(s10_kappa_zeta_diff_4, S, _, _) :- value_at(S,kappa,A), value_at(S,zeta,B), A-B =:= 4.
constraint_holds(s11_gamma_alpha_diff_3, S, _, _) :- value_at(S,gamma,A), value_at(S,alpha,B), A-B =:= 3.
constraint_holds(s12_theta_eta_diff_2, S, _, _) :- value_at(S,theta,A), value_at(S,eta,B), A-B =:= 2.
constraint_holds(n1_alpha_iota_slot, S, N, _) :- value_at(N,alpha,A), value_at(S,iota,B), A =:= B.
constraint_holds(n2_beta_epsilon_slot, S, N, _) :- value_at(N,beta,A), value_at(S,epsilon,B), A =:= B.
constraint_holds(n3_gamma_zeta_slot, S, N, _) :- value_at(N,gamma,A), value_at(S,zeta,B), A =:= B.
constraint_holds(n4_delta_gamma_slot, S, N, _) :- value_at(N,delta,A), value_at(S,gamma,B), A =:= B.
constraint_holds(n5_epsilon_delta_slot, S, N, _) :- value_at(N,epsilon,A), value_at(S,delta,B), A =:= B.
constraint_holds(n6_zeta_alpha_slot, S, N, _) :- value_at(N,zeta,A), value_at(S,alpha,B), A =:= B.
constraint_holds(n7_eta_beta_slot, S, N, _) :- value_at(N,eta,A), value_at(S,beta,B), A =:= B.
constraint_holds(n8_theta_eta_slot, S, N, _) :- value_at(N,theta,A), value_at(S,eta,B), A =:= B.
constraint_holds(n9_iota_theta_slot, S, N, _) :- value_at(N,iota,A), value_at(S,theta,B), A =:= B.
constraint_holds(n10_kappa_kappa_slot, S, N, _) :- value_at(N,kappa,A), value_at(S,kappa,B), A =:= B.
constraint_holds(p1_alpha_theta_slot, S, _, P) :- value_at(P,alpha,A), value_at(S,theta,B), A =:= B.
constraint_holds(p2_beta_epsilon_node, _, N, P) :- value_at(P,beta,A), value_at(N,epsilon,B), A =:= B.
constraint_holds(p3_gamma_eta_slot, S, _, P) :- value_at(P,gamma,A), value_at(S,eta,B), A =:= B.
constraint_holds(p4_delta_eta_node, _, N, P) :- value_at(P,delta,A), value_at(N,eta,B), A =:= B.
constraint_holds(p5_epsilon_delta_node, _, N, P) :- value_at(P,epsilon,A), value_at(N,delta,B), A =:= B.
constraint_holds(p6_zeta_kappa_slot, S, _, P) :- value_at(P,zeta,A), value_at(S,kappa,B), A =:= B.
constraint_holds(p7_eta_gamma_node, _, N, P) :- value_at(P,eta,A), value_at(N,gamma,B), A =:= B.
constraint_holds(p8_theta_beta_node, _, N, P) :- value_at(P,theta,A), value_at(N,beta,B), A =:= B.
constraint_holds(p9_iota_zeta_node, _, N, P) :- value_at(P,iota,A), value_at(N,zeta,B), A =:= B.
constraint_holds(p10_kappa_iota_slot, S, _, P) :- value_at(P,kappa,A), value_at(S,iota,B), A =:= B.
constraint_holds(g1_two_selected_slots_even, S, _, _) :-
    maplist(value_at(S), [alpha,delta,eta,iota], Values), even_count(Values, 2).
constraint_holds(g2_phase_subset_sum_14, _, _, P) :-
    maplist(value_at(P), [beta,delta,zeta,kappa], [A,B,C,D]), A+B+C+D =:= 14.
constraint_holds(g3_node_epsilon_theta_sum_10, _, N, _) :- value_at(N,epsilon,A), value_at(N,theta,B), A+B =:= 10.
constraint_holds(g4_slot_gamma_epsilon_sum_19, S, _, _) :- value_at(S,gamma,A), value_at(S,epsilon,B), A+B =:= 19.
constraint_holds(g5_biconditional_alpha_eta_theta_iota, S, N, P) :-
    value_at(S,alpha,A), value_at(S,eta,G), value_at(P,theta,PH), value_at(N,iota,NI),
    truth_value(A > G, Left), truth_value(PH > NI, Right), Left == Right.
constraint_holds(g6_biconditional_epsilon_theta_epsilon_beta, S, N, P) :-
    value_at(S,epsilon,E), value_at(S,theta,H), value_at(P,epsilon,PE), value_at(N,beta,NB),
    truth_value(E > H, Left), truth_value(PE > NB, Right), Left == Right.
constraint_holds(g7_node_alpha_lt_slot_delta, S, N, _) :- value_at(N,alpha,A), value_at(S,delta,D), A < D.
constraint_holds(g8_phase_gamma_eta_sum_7, _, _, P) :- value_at(P,gamma,A), value_at(P,eta,B), A+B =:= 7.
constraint_holds(g9_node_delta_gamma_diff_9, _, N, _) :- value_at(N,delta,A), value_at(N,gamma,B), A-B =:= 9.

truth_value(Goal, true) :- call(Goal), !.
truth_value(_, false).

apply_slot_constraints(S) :-
    S = [A,B,C,D,E,F,G,H,I,J],
    A+B #= 9,
    C-D #= 6,
    E+F #= 10,
    G+I #= 9,
    H-J #= 3,
    A-J #= 2,
    E-H #= 1,
    G-D #= 2,
    I-B #= 1,
    J-F #= 4,
    C-A #= 3,
    H-G #= 2.

apply_node_constraints(S, N) :-
    S = [A,B,C,D,E,F,G,H,I,J],
    N = [NA,NB,NC,ND,NE,NF,NG,NH,NI,NJ],
    NA #= I,
    NB #= E,
    NC #= F,
    ND #= C,
    NE #= D,
    NF #= A,
    NG #= B,
    NH #= G,
    NI #= H,
    NJ #= J.

apply_phase_constraints(S, N, P) :-
    S = [_,_,_,_,_,_,G,H,I,J],
    N = [_,NB,NC,ND,NE,NF,NG,_,_,_],
    P = [PA,PB,PC,PD,PE,PF,PG,PH,PI,PJ],
    PA #= H,
    PB #= NE,
    PC #= G,
    PD #= NG,
    PE #= ND,
    PF #= J,
    PG #= NC,
    PH #= NB,
    PI #= NF,
    PJ #= I.

apply_global_constraints(S, N, P) :-
    S = [A,_,C,D,E,_,G,H,I,_],
    N = [NA,NB,NC,ND,NE,_,_,NH,NI,_],
    P = [_,PB,PC,PD,PE,PF,PG,PH,_,PJ],
    reified_even(A, BA),
    reified_even(D, BD),
    reified_even(G, BG),
    reified_even(I, BI),
    BA+BD+BG+BI #= 2,
    PB+PD+PF+PJ #= 14,
    NE+NH #= 10,
    C+E #= 19,
    (A #> G) #<==> (PH #> NI),
    (E #> H) #<==> (PE #> NB),
    NA #< D,
    PC+PG #= 7,
    ND-NC #= 9.

reified_even(Value, Bool) :-
    Bool in 0..1,
    Bool #<==> (Value mod 2 #= 0).

values_assignment(Slots, Nodes, Phases, _{assignments:Rows}) :-
    canonical_tasks(Tasks),
    maplist(value_row(Slots, Nodes, Phases), Tasks, Rows).

value_row(Slots, Nodes, Phases, Task,
          _{task:Task, slot:Slot, node:Node, phase:Phase}) :-
    value_at(Slots, Task, Slot),
    value_at(Nodes, Task, Node),
    value_at(Phases, Task, Phase).

extract_json_object(Text0, Json) :-
    normalize_space(string(Text), Text0),
    sub_string(Text, Start, _, _, "{"),
    string_length(Text, Length),
    reverse_between(0, Length, End),
    sub_string(Text, End, 1, _, "}"),
    End >= Start,
    !,
    JsonLength is End-Start+1,
    sub_string(Text, Start, JsonLength, _, Json).
extract_json_object(_, _) :-
    throw(constraint_shape(no_json_object)).

reverse_between(Low, High, Value) :-
    between(Low, High, Offset),
    Value is High-Offset.

text_string(Value, Value) :- string(Value), !.
text_string(Value, Text) :- atom(Value), !, atom_string(Value, Text).
text_string(Value, _) :- throw(constraint_shape(not_text(Value))).

verification_exception(Phase, Exception,
                       error(constraint_verification_error{
                                 phase:Phase,
                                 detail:Safe
                             })) :-
    safe_term(Exception, Safe).

safe_term(Term, Safe) :-
    term_string(Term, Safe, [quoted(true), numbervars(true)]).
