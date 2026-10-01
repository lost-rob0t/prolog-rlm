:- module(rlm_image_tool_pack,
          [ load_image_tool_pack/2
          ]).

/** <module> Image-generation tool pack

The tool is deliberately a `network_write` effect because generation may
consume paid remote inference and may create provider-side artifacts.  Loading
this pack grants no capability and does not set authority.
*/

:- use_module(rlm_image).
:- use_module(rlm_tool).
:- use_module(rlm_tool_loader).

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack(image_models,
                          rlm_image_tool_pack:load_image_tool_pack).

rlm_tool_loader:tool_pack_manifest(
    image_models,
    tool_pack_manifest{
        library:prolog_rlm_image,
        category:image,
        tools:[
            tool_export{name:image_generate,
                        capability:tool(image_generate),
                        effect:network_write}
        ]
    }).

load_image_tool_pack(Registry, Outcome) :-
    image_generate_schema(Schema),
    tool_register(Registry,
                  Schema,
                  rlm_image_tool_pack:image_generate_handler,
                  RegisterOutcome),
    (   RegisterOutcome = ok(_)
    ->  Outcome = ok(tool_pack{pack:image_models,
                               registered:[image_generate]})
    ;   Outcome = RegisterOutcome
    ).

image_generate_schema(
    tool_schema{
        name:image_generate,
        description:"Generate images with the configured OpenAI-compatible image model provider",
        capability:tool(image_generate),
        effect:network_write,
        arguments:_{
            type:object,
            required:[prompt],
            additional_properties:false,
            properties:_{
                prompt:_{type:string},
                n:_{type:integer},
                size:_{type:string},
                quality:_{type:string},
                style:_{type:string},
                background:_{type:string},
                output_format:_{type:string},
                response_format:_{type:string},
                moderation:_{type:string}
            }
        },
        result:_{type:any},
        limits:_{time_limit:90.0, max_output_bytes:25165824}
    }).

image_generate_handler(Args, Result) :-
    image_generate_execute(default, Args, Outcome),
    image_result(Outcome, Result).

image_result(ok(Result), Result) :-
    !.
image_result(error(Error), _) :-
    throw(error(image_generation_failed(Error), _)).
