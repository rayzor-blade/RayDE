#include <git2.h>
#include <stddef.h>
#include <stdio.h>

#define SIZE(type, bytes) _Static_assert(sizeof(type) == bytes, #type " size")
#define OFFSET(type, field, bytes) _Static_assert(offsetof(type, field) == bytes, #type "." #field)

SIZE(git_oid, 20);
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
