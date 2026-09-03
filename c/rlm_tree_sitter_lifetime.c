#include "rlm_tree_sitter_internal.h"

bool language_abi_supported(unsigned int abi)
{
    return abi >= TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION &&
           abi <= TREE_SITTER_LANGUAGE_VERSION;
}

static bool language_retire_locked(rlm_ts_language_resource *resource)
{
    if (!resource->public_open && resource->dependents == 0 && resource->library) {
        dlclose(resource->library);
        resource->library = NULL;
        resource->language = NULL;
    }
    return !resource->blob_alive && resource->dependents == 0;
}

static void language_finish_free(rlm_ts_language_resource *resource)
{
    pthread_mutex_destroy(&resource->lock);
    free(resource);
}

bool language_retain(rlm_ts_language_resource *resource,
                     bool require_public_open,
                     const TSLanguage **language)
{
    bool retained = false;

    if (!resource) {
        return false;
    }
    pthread_mutex_lock(&resource->lock);
    if (resource->library &&
        resource->language &&
        (!require_public_open || resource->public_open) &&
        resource->dependents < UINT_MAX) {
        resource->dependents++;
        if (language) {
            *language = resource->language;
        }
        retained = true;
    }
    pthread_mutex_unlock(&resource->lock);
    return retained;
}

void language_release(rlm_ts_language_resource *resource)
{
    bool free_now = false;

    if (!resource) {
        return;
    }
    pthread_mutex_lock(&resource->lock);
    if (resource->dependents > 0) {
        resource->dependents--;
    }
    free_now = language_retire_locked(resource);
    pthread_mutex_unlock(&resource->lock);
    if (free_now) {
        language_finish_free(resource);
    }
}

bool language_snapshot_open(rlm_ts_language_resource *resource,
                            const TSLanguage **language,
                            unsigned int *abi)
{
    bool open = false;

    if (!resource) {
        return false;
    }
    pthread_mutex_lock(&resource->lock);
    if (resource->public_open && resource->library && resource->language) {
        if (language) {
            *language = resource->language;
        }
        if (abi) {
            *abi = resource->abi;
        }
        open = true;
    }
    pthread_mutex_unlock(&resource->lock);
    return open;
}

bool language_close_public(rlm_ts_language_resource *resource)
{
    bool was_open;
    bool free_now;

    pthread_mutex_lock(&resource->lock);
    was_open = resource->public_open;
    resource->public_open = false;
    free_now = language_retire_locked(resource);
    pthread_mutex_unlock(&resource->lock);
    if (free_now) {
        language_finish_free(resource);
    }
    return was_open;
}

static void tree_finish_free(rlm_ts_tree_resource *resource,
                             TSTree *tree,
                             rlm_ts_language_resource *language)
{
    if (tree) {
        ts_tree_delete(tree);
    }
    if (language) {
        language_release(language);
    }
    pthread_mutex_destroy(&resource->lock);
    free(resource);
}

void tree_retain_node(rlm_ts_tree_resource *resource)
{
    if (!resource) {
        return;
    }
    pthread_mutex_lock(&resource->lock);
    if (resource->node_refs < UINT_MAX) {
        resource->node_refs++;
    }
    pthread_mutex_unlock(&resource->lock);
}

void tree_release_node(rlm_ts_tree_resource *resource)
{
    bool free_now = false;
    TSTree *tree = NULL;
    rlm_ts_language_resource *language = NULL;

    if (!resource) {
        return;
    }
    pthread_mutex_lock(&resource->lock);
    if (resource->node_refs > 0) {
        resource->node_refs--;
    }
    if (!resource->blob_alive && resource->node_refs == 0) {
        free_now = true;
        if (resource->open) {
            tree = resource->tree;
            language = resource->language;
            resource->tree = NULL;
            resource->language = NULL;
            resource->open = false;
        }
    }
    pthread_mutex_unlock(&resource->lock);
    if (free_now) {
        tree_finish_free(resource, tree, language);
    }
}

int release_language_blob(atom_t atom)
{
    size_t length = 0;
    PL_blob_t *type = NULL;
    void *data = PL_blob_data(atom, &length, &type);

    if (data && type == &language_blob && length == sizeof(rlm_ts_language_resource *)) {
        rlm_ts_language_resource *resource = *(rlm_ts_language_resource **)data;
        if (resource) {
            bool free_now;
            pthread_mutex_lock(&resource->lock);
            resource->blob_alive = false;
            resource->public_open = false;
            free_now = language_retire_locked(resource);
            pthread_mutex_unlock(&resource->lock);
            if (free_now) {
                language_finish_free(resource);
            }
        }
    }
    return TRUE;
}

int release_parser_blob(atom_t atom)
{
    size_t length = 0;
    PL_blob_t *type = NULL;
    void *data = PL_blob_data(atom, &length, &type);

    if (data && type == &parser_blob && length == sizeof(rlm_ts_parser_resource *)) {
        rlm_ts_parser_resource *resource = *(rlm_ts_parser_resource **)data;
        if (resource) {
            if (resource->open && resource->parser) {
                ts_parser_delete(resource->parser);
                resource->parser = NULL;
                resource->open = false;
                language_release(resource->language);
                resource->language = NULL;
            }
            free(resource);
        }
    }
    return TRUE;
}

int release_tree_blob(atom_t atom)
{
    size_t length = 0;
    PL_blob_t *type = NULL;
    void *data = PL_blob_data(atom, &length, &type);

    if (data && type == &tree_blob && length == sizeof(rlm_ts_tree_resource *)) {
        rlm_ts_tree_resource *resource = *(rlm_ts_tree_resource **)data;
        if (resource) {
            bool free_now = false;
            TSTree *tree = NULL;
            rlm_ts_language_resource *language = NULL;
            pthread_mutex_lock(&resource->lock);
            resource->blob_alive = false;
            if (resource->node_refs == 0) {
                free_now = true;
                if (resource->open) {
                    tree = resource->tree;
                    language = resource->language;
                    resource->tree = NULL;
                    resource->language = NULL;
                    resource->open = false;
                }
            }
            pthread_mutex_unlock(&resource->lock);
            if (free_now) {
                tree_finish_free(resource, tree, language);
            }
        }
    }
    return TRUE;
}

int release_node_blob(atom_t atom)
{
    size_t length = 0;
    PL_blob_t *type = NULL;
    void *data = PL_blob_data(atom, &length, &type);

    if (data && type == &node_blob && length == sizeof(rlm_ts_node_resource *)) {
        rlm_ts_node_resource *resource = *(rlm_ts_node_resource **)data;
        if (resource) {
            tree_release_node(resource->tree);
            free(resource->named_fields);
            free(resource);
        }
    }
    return TRUE;
}

static bool query_retire_locked(rlm_ts_query_resource *resource,
                                TSQuery **query,
                                rlm_ts_language_resource **language)
{
    if (!resource->open && resource->dependents == 0 && resource->query) {
        *query = resource->query;
        *language = resource->language;
        resource->query = NULL;
        resource->language = NULL;
    }
    return !resource->blob_alive && resource->dependents == 0;
}

static void query_delete_native(TSQuery *query,
                                rlm_ts_language_resource *language)
{
    if (query) {
        ts_query_delete(query);
    }
    if (language) {
        language_release(language);
    }
}

static void query_finish_free(rlm_ts_query_resource *resource)
{
    pthread_mutex_destroy(&resource->lock);
    free(resource);
}

bool query_retain(rlm_ts_query_resource *resource,
                  const TSQuery **query)
{
    bool retained = false;

    if (!resource) {
        return false;
    }
    pthread_mutex_lock(&resource->lock);
    if (resource->open && resource->query && resource->dependents < UINT_MAX) {
        resource->dependents++;
        if (query) {
            *query = resource->query;
        }
        retained = true;
    }
    pthread_mutex_unlock(&resource->lock);
    return retained;
}

void query_release(rlm_ts_query_resource *resource)
{
    TSQuery *query = NULL;
    rlm_ts_language_resource *language = NULL;
    bool free_now;

    if (!resource) {
        return;
    }
    pthread_mutex_lock(&resource->lock);
    if (resource->dependents > 0) {
        resource->dependents--;
    }
    free_now = query_retire_locked(resource, &query, &language);
    pthread_mutex_unlock(&resource->lock);
    query_delete_native(query, language);
    if (free_now) {
        query_finish_free(resource);
    }
}

int release_query_blob(atom_t atom)
{
    size_t length = 0;
    PL_blob_t *type = NULL;
    void *data = PL_blob_data(atom, &length, &type);

    if (data && type == &query_blob && length == sizeof(rlm_ts_query_resource *)) {
        rlm_ts_query_resource *resource = *(rlm_ts_query_resource **)data;
        if (resource) {
            TSQuery *query = NULL;
            rlm_ts_language_resource *language = NULL;
            bool free_now;
            pthread_mutex_lock(&resource->lock);
            resource->blob_alive = false;
            resource->open = false;
            free_now = query_retire_locked(resource, &query, &language);
            pthread_mutex_unlock(&resource->lock);
            query_delete_native(query, language);
            if (free_now) {
                query_finish_free(resource);
            }
        }
    }
    return TRUE;
}

int release_query_cursor_blob(atom_t atom)
{
    size_t length = 0;
    PL_blob_t *type = NULL;
    void *data = PL_blob_data(atom, &length, &type);

    if (data && type == &query_cursor_blob &&
        length == sizeof(rlm_ts_query_cursor_resource *)) {
        rlm_ts_query_cursor_resource *resource =
            *(rlm_ts_query_cursor_resource **)data;
        if (resource) {
            if (resource->open && resource->cursor) {
                ts_query_cursor_delete(resource->cursor);
                resource->cursor = NULL;
                resource->open = false;
            }
            query_release(resource->query);
            tree_release_node(resource->tree);
            free(resource);
        }
    }
    return TRUE;
}
