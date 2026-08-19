#include "rlm_tree_sitter_internal.h"

foreign_t pl_ts_runtime_abi(term_t minimum, term_t maximum)
{
    return PL_unify_integer(minimum, TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION) &&
           PL_unify_integer(maximum, TREE_SITTER_LANGUAGE_VERSION);
}

foreign_t pl_ts_language_load(term_t path_term, term_t symbol_term, term_t language_term)
{
    char *path = NULL;
    char *symbol_name = NULL;
    size_t path_length = 0;
    size_t symbol_length = 0;
    void *library = NULL;
    void *symbol = NULL;
    rlm_ts_language_entry entry = NULL;
    const TSLanguage *language = NULL;
    rlm_ts_language_resource *resource = NULL;
    unsigned int abi;
    char detail[512];

    if (!get_utf8_text(path_term, &path, &path_length)) {
        return FALSE;
    }
    if (!get_utf8_text(symbol_term, &symbol_name, &symbol_length)) {
        PL_free(path);
        return FALSE;
    }
    if (path_length == 0 || symbol_length == 0) {
        PL_free(path);
        PL_free(symbol_name);
        return raise_tree_sitter_error("invalid_loader_argument", "library path and entry symbol must be non-empty");
    }

    dlerror();
    library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        const char *error = dlerror();
        snprintf(detail, sizeof(detail), "%s", error ? error : "dlopen failed without diagnostic");
        PL_free(path);
        PL_free(symbol_name);
        return raise_tree_sitter_error("load_library", detail);
    }

    dlerror();
    symbol = dlsym(library, symbol_name);
    {
        const char *error = dlerror();
        if (error || !symbol) {
            snprintf(detail, sizeof(detail), "%s", error ? error : "grammar entry symbol not found");
            dlclose(library);
            PL_free(path);
            PL_free(symbol_name);
            return raise_tree_sitter_error("load_symbol", detail);
        }
    }

    if (sizeof(entry) != sizeof(symbol)) {
        dlclose(library);
        PL_free(path);
        PL_free(symbol_name);
        return raise_tree_sitter_error("platform_abi", "function pointer representation is unsupported on this platform");
    }
    memcpy(&entry, &symbol, sizeof(entry));
    language = entry();
    if (!language) {
        dlclose(library);
        PL_free(path);
        PL_free(symbol_name);
        return raise_tree_sitter_error("null_language", "grammar entry symbol returned NULL");
    }

    abi = (unsigned int)RLM_TS_LANGUAGE_ABI(language);
    if (!language_abi_supported(abi)) {
        snprintf(detail,
                 sizeof(detail),
                 "grammar ABI %u is outside runtime range %u..%u",
                 abi,
                 (unsigned int)TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION,
                 (unsigned int)TREE_SITTER_LANGUAGE_VERSION);
        dlclose(library);
        PL_free(path);
        PL_free(symbol_name);
        return raise_tree_sitter_error("incompatible_language_abi", detail);
    }

    resource = calloc(1, sizeof(*resource));
    if (!resource) {
        dlclose(library);
        PL_free(path);
        PL_free(symbol_name);
        return PL_resource_error("memory");
    }
    if (pthread_mutex_init(&resource->lock, NULL) != 0) {
        dlclose(library);
        PL_free(path);
        PL_free(symbol_name);
        free(resource);
        return PL_resource_error("memory");
    }
    resource->library = library;
    resource->language = language;
    resource->abi = abi;
    resource->blob_alive = true;
    resource->public_open = true;

    PL_free(path);
    PL_free(symbol_name);
    return unify_language(language_term, resource);
}

foreign_t pl_ts_language_abi(term_t language_term, term_t abi_term)
{
    rlm_ts_language_resource *resource;
    unsigned int abi;

    if (!get_language(language_term, &resource)) {
        return FALSE;
    }
    if (!language_snapshot_open(resource, NULL, &abi)) {
        return raise_tree_sitter_error("closed_language", "language handle is closed");
    }
    return PL_unify_integer(abi_term, abi);
}

foreign_t pl_ts_language_close(term_t language_term, term_t status_term)
{
    rlm_ts_language_resource *resource;

    if (!get_language(language_term, &resource)) {
        return FALSE;
    }
    if (!language_close_public(resource)) {
        return PL_unify_atom_chars(status_term, "already_closed");
    }
    return PL_unify_atom_chars(status_term, "closed");
}
