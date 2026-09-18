:- module(rlm_browser_tool_pack,
          [ load_browser_tool_pack/2
          ]).

/** <module> Browser tools projected through the Zara browser bridge

The pack advertises a closed browser category.  Read-only observation tools are
`read` effects.  Operations that can change browser state or trigger external
network effects are `network_write`, so they cross the normal capability and
authority boundary before the trusted handler is called.

The browser add-on remains responsible for DOM/browser API execution.  This
module never handles cookies, passwords, CAPTCHA tokens, or browser profile
storage directly.
*/

:- use_module(rlm_browser).
:- use_module(rlm_tool).
:- use_module(rlm_tool_loader).

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack(browser_core,
                          rlm_browser_tool_pack:load_browser_tool_pack).

rlm_tool_loader:tool_pack_manifest(
    browser_core,
    tool_pack_manifest{
        library:prolog_rlm_browser,
        category:browser,
        tools:[
            tool_export{name:browser_tabs,
                        capability:tool(browser_tabs),
                        effect:read},
            tool_export{name:browser_read,
                        capability:tool(browser_read),
                        effect:read},
            tool_export{name:browser_elements,
                        capability:tool(browser_elements),
                        effect:read},
            tool_export{name:browser_extract,
                        capability:tool(browser_extract),
                        effect:read},
            tool_export{name:browser_screenshot,
                        capability:tool(browser_screenshot),
                        effect:read},
            tool_export{name:browser_open,
                        capability:tool(browser_open),
                        effect:network_write},
            tool_export{name:browser_navigate,
                        capability:tool(browser_navigate),
                        effect:network_write},
            tool_export{name:browser_click,
                        capability:tool(browser_click),
                        effect:network_write},
            tool_export{name:browser_type,
                        capability:tool(browser_type),
                        effect:network_write},
            tool_export{name:browser_submit,
                        capability:tool(browser_submit),
                        effect:network_write}
        ]
    }).

load_browser_tool_pack(Registry, Outcome) :-
    findall(browser_tool(Name, Action, Effect, Description, Arguments),
            browser_tool_definition(Name,
                                    Action,
                                    Effect,
                                    Description,
                                    Arguments),
            Tools),
    register_browser_tools(Tools, Registry, [], Outcome).

register_browser_tools([], _, Registered0,
                       ok(tool_pack{pack:browser_core,
                                    registered:Registered})) :-
    reverse(Registered0, Registered).
register_browser_tools([browser_tool(Name, Action, Effect, Description,
                                    Arguments)|Tools],
                       Registry,
                       Registered0,
                       Outcome) :-
    browser_schema(Name, Effect, Description, Arguments, Schema),
    Handler = rlm_browser_tool_pack:browser_handler(Action),
    tool_register(Registry, Schema, Handler, RegisterOutcome),
    register_browser_after(RegisterOutcome,
                           Name,
                           Tools,
                           Registry,
                           Registered0,
                           Outcome).

register_browser_after(error(Error), _, _, _, _, error(Error)) :-
    !.
register_browser_after(ok(_), Name, Tools, Registry, Registered0, Outcome) :-
    register_browser_tools(Tools, Registry, [Name|Registered0], Outcome).

browser_handler(Action, Args, Result) :-
    browser_bridge_call(Action, Args, Outcome),
    browser_result(Outcome, Result).

browser_result(ok(Result), Result) :-
    !.
browser_result(error(Error), _) :-
    throw(error(browser_bridge_failed(Error), _)).

browser_schema(Name, Effect, Description, Arguments,
               tool_schema{
                   name:Name,
                   description:Description,
                   capability:tool(Name),
                   effect:Effect,
                   arguments:Arguments,
                   result:_{type:any},
                   limits:_{time_limit:25.0, max_output_bytes:12582912}
               }).

browser_tool_definition(
    browser_tabs,
    tabs_list,
    read,
    "List open browser tabs with sanitized tab metadata",
    _{type:object,
      required:[],
      additional_properties:false,
      properties:_{}}).

browser_tool_definition(
    browser_read,
    page_read,
    read,
    "Read visible text and basic metadata from a browser page",
    _{type:object,
      required:[],
      additional_properties:false,
      properties:_{
          tab_id:_{type:integer},
          max_chars:_{type:integer}
      }}).

browser_tool_definition(
    browser_elements,
    page_elements,
    read,
    "List bounded interactive page elements with generated CSS selectors",
    _{type:object,
      required:[],
      additional_properties:false,
      properties:_{
          tab_id:_{type:integer},
          max_items:_{type:integer}
      }}).

browser_tool_definition(
    browser_extract,
    page_extract,
    read,
    "Extract bounded text and attributes from one CSS selector",
    _{type:object,
      required:[selector],
      additional_properties:false,
      properties:_{
          selector:_{type:string},
          tab_id:_{type:integer},
          max_chars:_{type:integer}
      }}).

browser_tool_definition(
    browser_screenshot,
    page_screenshot,
    read,
    "Capture the visible active page as an image data URL for multimodal models",
    _{type:object,
      required:[],
      additional_properties:false,
      properties:_{
          tab_id:_{type:integer}
      }}).

browser_tool_definition(
    browser_open,
    tabs_open,
    network_write,
    "Open an HTTP or HTTPS URL in a new browser tab",
    _{type:object,
      required:[url],
      additional_properties:false,
      properties:_{
          url:_{type:string},
          active:_{type:boolean}
      }}).

browser_tool_definition(
    browser_navigate,
    tabs_navigate,
    network_write,
    "Navigate an existing browser tab to an HTTP or HTTPS URL",
    _{type:object,
      required:[url],
      additional_properties:false,
      properties:_{
          url:_{type:string},
          tab_id:_{type:integer}
      }}).

browser_tool_definition(
    browser_click,
    page_click,
    network_write,
    "Click an element selected by CSS in the browser page",
    _{type:object,
      required:[selector],
      additional_properties:false,
      properties:_{
          selector:_{type:string},
          tab_id:_{type:integer}
      }}).

browser_tool_definition(
    browser_type,
    page_type,
    network_write,
    "Type bounded text into an input, textarea, or contenteditable element",
    _{type:object,
      required:[selector, text],
      additional_properties:false,
      properties:_{
          selector:_{type:string},
          text:_{type:string},
          tab_id:_{type:integer},
          clear:_{type:boolean}
      }}).

browser_tool_definition(
    browser_submit,
    page_submit,
    network_write,
    "Submit a selected form or activate its selected submit control",
    _{type:object,
      required:[selector],
      additional_properties:false,
      properties:_{
          selector:_{type:string},
          tab_id:_{type:integer}
      }}).
