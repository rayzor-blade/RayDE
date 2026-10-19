#include <git2.h>
#include <stddef.h>
#include <stdio.h>

#define SIZE(type, bytes) _Static_assert(sizeof(type) == bytes, #type " size")
#define OFFSET(type, field, bytes) _Static_assert(offsetof(type, field) == bytes, #type "." #field)

SIZE(git_oid, 20);
SIZE(git_buf, 24);
SIZE(git_merge_options, 48);
SIZE(git_checkout_options, 144);
SIZE(git_rebase_options, 240);
OFFSET(git_rebase_options, inmemory, 8);
OFFSET(git_rebase_options, merge_options, 24);
OFFSET(git_rebase_options, checkout_options, 72);
OFFSET(git_rebase_options, commit_create_cb, 216);
OFFSET(git_rebase_options, payload, 232);
SIZE(git_remote_callbacks, 128);
OFFSET(git_remote_callbacks, push_update_reference, 72);
OFFSET(git_remote_callbacks, update_refs, 120);
SIZE(git_proxy_options, 40);
SIZE(git_push_options, 216);
OFFSET(git_push_options, callbacks, 8);
OFFSET(git_push_options, proxy_opts, 136);
OFFSET(git_push_options, custom_headers, 184);
OFFSET(git_push_options, remote_push_options, 200);
OFFSET(git_signature, name, 0);
OFFSET(git_signature, email, 8);
SIZE(git_diff_file, 48);
OFFSET(git_diff_file, path, 24);
OFFSET(git_diff_file, size, 32);
OFFSET(git_diff_file, mode, 44);
SIZE(git_diff_delta, 112);
OFFSET(git_diff_delta, old_file, 16);
OFFSET(git_diff_delta, new_file, 64);
SIZE(git_diff_binary_file, 32);
SIZE(git_diff_binary, 72);
OFFSET(git_diff_binary, old_file, 8);
OFFSET(git_diff_binary, new_file, 40);
SIZE(git_diff_hunk, 152);
OFFSET(git_diff_hunk, header_len, 16);
OFFSET(git_diff_hunk, header, 24);
SIZE(git_diff_line, 40);
OFFSET(git_diff_line, old_lineno, 4);
OFFSET(git_diff_line, content_len, 16);
OFFSET(git_diff_line, content_offset, 24);
OFFSET(git_diff_line, content, 32);
SIZE(git_status_entry, 24);
OFFSET(git_status_entry, head_to_index, 8);
OFFSET(git_status_entry, index_to_workdir, 16);
SIZE(git_status_options, 48);
OFFSET(git_status_options, pathspec, 16);
OFFSET(git_status_options, baseline, 32);
OFFSET(git_status_options, rename_threshold, 40);
SIZE(git_diff_options, 96);
OFFSET(git_diff_options, pathspec, 16);
OFFSET(git_diff_options, notify_cb, 32);
OFFSET(git_diff_options, context_lines, 56);
OFFSET(git_diff_options, oid_type, 64);
OFFSET(git_diff_options, max_size, 72);
OFFSET(git_diff_options, new_prefix, 88);

int main(void) { puts("git native: pinned C layouts"); }
