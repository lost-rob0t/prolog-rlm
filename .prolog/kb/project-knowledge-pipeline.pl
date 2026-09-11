/* Project knowledge pipeline architecture (issues #93-#99, #377, #380). */

pipeline_layer(94, direct_tree_sitter_ffi, done).
pipeline_layer(95, declarative_source_registry, done).
pipeline_layer(96, versioned_cst_observations, done).
pipeline_layer(97, grouped_query_captures, done).
pipeline_layer(98, semantic_normalization, done).
pipeline_layer(99, freshness_coherent_snapshots, open).
pipeline_consumer(380, project_symbolic_knowledge_expert, depends_on([377, 99])).
pipeline_consumer(381, retrieval_evidence_expert, depends_on([380])).

% #98 public semantic surface contract (prolog/rlm_project_semantic.pl):
% normalize/execute -> Future -> sync await; reads answer only while the
% underlying #97 extraction is current; knowledge_state reports
% current/stale/none; resolution (resolved/unresolved/ambiguous/external) is
% a separate bounded pass; the symbol_index carries coherence keys and is
% consumed by plan_graph_resolve_symbol (which reads keys via get_dict).
semantic_layer(98, 'rlm_project_semantic', facts, ['normalize', 'knowledge_state', 'definitions', 'references', 'calls', 'imports', 'exports', 'contains', 'call_reachable', 'file_dependencies', 'resolve', 'symbol_index']).
semantic_layer_adapter_protocol('capture names: @relation[.kind] principal + @relation.role details paired by native order inside one grouped match').
semantic_layer_persistence('.kb/project-semantic per project identity; currentness never journaled; the #97 extraction journal stays authoritative').

% Semantic pack conventions for future language adapters:
% pack sources stay inert; predicate-bearing query patterns are rejected by
% the #97 layer; capture-name suffixes beyond the closed 13-atom symbol_kind
% set are silently unclassified (deliberate: unclassified captures are
% ignored, unknown capture-name shapes fault).
semantic_pack_rule(unclassified_kind_capture_is_ignored).
semantic_pack_rule(unknown_capture_name_faults).