/*
 * Copyright (c) 2004-2006 Hyperic, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "sigar.h"
#include "sigar_private.h"
#include "sigar_util.h"
#include <stdio.h>
/*
 * hash table to cache values where key is a unique number
 * such as:
 *  pid -> some process data
 *  uid -> user name
 *  gid -> group name
 */

#define ENTRIES_SIZE(n) \
    (sizeof(sigar_cache_entry_t *) * (n))

/* wrap free() for use w/ dmalloc */
static void free_value(void *ptr)
{
    free(ptr);
}

sigar_cache_t *sigar_expired_cache_new(int size, sigar_uint64_t cleanup_period_millis, sigar_uint64_t entry_expire_period)
{
    sigar_cache_t *table = malloc(sizeof(*table));
    table->count = 0;
    table->size = size;
    table->entries = malloc(ENTRIES_SIZE(size));
    memset(table->entries, '\0', ENTRIES_SIZE(size));
    table->free_value = free_value;
    table->cleanup_period_millis = cleanup_period_millis;
    table->last_cleanup_time = sigar_time_now_millis();
    table->entry_expire_period = entry_expire_period;
    return table;
}

sigar_cache_t *sigar_cache_new(int size)
{
    return sigar_expired_cache_new(size, SIGAR_FIELD_NOTIMPL, SIGAR_FIELD_NOTIMPL);
}


/*#ifdef DEBUG_CACHE*/
/* see how well entries are distributed */
void sigar_cache_dump(sigar_cache_t *table)
{
    int i;
    sigar_cache_entry_t **entries = table->entries;
    printf("table size %lu\n", (long)table->size); 
    printf("table count %lu\n", (long)table->count);
    
    for (i=0; i<table->size; i++) {
        sigar_cache_entry_t *entry = *entries++;

        printf("|");
        while (entry) {
            printf("%lld", entry->id);
            if (entry->next) {
                printf(",");
            }
            entry = entry->next;
        }
    }
    printf("\n");
    fflush(stdout);
}
/*#endif*/

static void sigar_cache_rehash(sigar_cache_t *table)
{
    int i;
    unsigned int new_size = table->count * 2 + 1;
    sigar_cache_entry_t **entries = table->entries;
    sigar_cache_entry_t **new_entries =
        malloc(ENTRIES_SIZE(new_size));

    memset(new_entries, '\0', ENTRIES_SIZE(new_size));

    for (i=0; i<table->size; i++) {
        sigar_cache_entry_t *entry = *entries++;

        while (entry) {
            sigar_cache_entry_t *next = entry->next;
            sigar_uint64_t hash = entry->id % new_size;

            entry->next = new_entries[hash];
            new_entries[hash] = entry;
            entry = next;
        }
    }

    free(table->entries);
    table->entries = new_entries;
    table->size = new_size;
}

#define SIGAR_CACHE_IX(t, k) \
    t->entries + (k % t->size)

void sigar_cache_prune(sigar_cache_t *table,
                       int (*remove_if)(const sigar_cache_entry_t *, void *),
                       void *data)
{
    unsigned int i;

    for (i=0; i<table->size; i++) {
        sigar_cache_entry_t **link = &table->entries[i];
        while (*link) {
            sigar_cache_entry_t *entry = *link;
            if (remove_if(entry, data)) {
                *link = entry->next;
                if (entry->value) {
                    table->free_value(entry->value);
                }
                free(entry);
                table->count--;
            }
            else {
                link = &entry->next;
            }
        }
    }
    if (table->count < (table->size/4)) {
        sigar_cache_rehash(table);
    }
}

typedef struct {
    sigar_uint64_t now;
    sigar_uint64_t expire_period;
} sigar_cache_expiry_t;

static int cache_entry_expired(const sigar_cache_entry_t *entry, void *data)
{
    const sigar_cache_expiry_t *expiry = data;
    return expiry->expire_period < expiry->now - entry->last_access_time;
}

void sigar_perform_cleanup_if_necessary(sigar_cache_t *table)
{
    sigar_cache_expiry_t expiry;

    if (table->cleanup_period_millis == SIGAR_FIELD_NOTIMPL) {
        return;
    }
    expiry.now = sigar_time_now_millis();
    if ((expiry.now - table->last_cleanup_time) < table->cleanup_period_millis) {
        return;
    }

    table->last_cleanup_time = expiry.now;
    expiry.expire_period = table->entry_expire_period;
    sigar_cache_prune(table, cache_entry_expired, &expiry);
}

sigar_cache_entry_t *sigar_cache_find(sigar_cache_t *table,
                                      sigar_uint64_t key)
{
    sigar_cache_entry_t *entry, **ptr;

    for (ptr = SIGAR_CACHE_IX(table, key), entry = *ptr;
         entry;
         ptr = &entry->next, entry = *ptr)
    {
        if (entry->id == key) {
            entry->last_access_time = sigar_time_now_millis();
            return entry;
        }
    }

    return NULL;
}

/* create entry if it does not exist */
sigar_cache_entry_t *sigar_cache_get(sigar_cache_t *table,
                                     sigar_uint64_t key)
{
    sigar_cache_entry_t *entry, **ptr;
    sigar_perform_cleanup_if_necessary(table);

    for (ptr = SIGAR_CACHE_IX(table, key), entry = *ptr;
         entry;
         ptr = &entry->next, entry = *ptr)
    {
        if (entry->id == key) {
            entry->last_access_time = sigar_time_now_millis();
            return entry;
        }
    }

    if (++table->count > table->size) {
        sigar_cache_rehash(table);

        for (ptr = SIGAR_CACHE_IX(table, key), entry = *ptr;
             entry;
             ptr = &entry->next, entry = *ptr)
        {
        }
    }

    *ptr = entry = malloc(sizeof(*entry));
    entry->id = key;
    entry->value = NULL;
    entry->next = NULL;
    entry->last_access_time = sigar_time_now_millis();

    return entry;
}

void sigar_cache_destroy(sigar_cache_t *table)
{
    int i;
    sigar_cache_entry_t **entries = table->entries;

#ifdef DEBUG_CACHE
    sigar_cache_dump(table);
#endif

    for (i=0; i<table->size; i++) {
        sigar_cache_entry_t *entry, *ptr;
        entry = *entries++;

        while (entry) {
            if (entry->value) {
                table->free_value(entry->value);
            }
            ptr = entry->next;
            free(entry);
            entry = ptr;
        }
    }

    free(table->entries);
    free(table);
}
