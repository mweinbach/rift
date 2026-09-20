#ifndef C_RIFT_FILESYSTEM_H
#define C_RIFT_FILESYSTEM_H

#include <stdint.h>

/* Every operation returns zero on success or the captured POSIX errno. */
enum rift_entry_type {
    RIFT_ENTRY_DIRECTORY = 1,
    RIFT_ENTRY_FILE = 2,
    RIFT_ENTRY_SYMLINK = 3,
    RIFT_ENTRY_UNSUPPORTED = 4
};

struct rift_file_info {
    uint64_t device;
    uint64_t inode;
    uint64_t link_count;
    uint32_t mode;
    uint32_t flags;
    int32_t type;
};

struct rift_metadata_error {
    int32_t code;
    const char *operation;
    int32_t source_path;
};

int32_t rift_read_file_info(const char *path, struct rift_file_info *info);
int32_t rift_clone_path(const char *source, const char *destination);
int32_t rift_create_directory(const char *path);
int32_t rift_create_hard_link(const char *existing, const char *destination);
int32_t rift_copy_symlink(const char *source, const char *destination);
int32_t rift_restore_cloned_file_mode(const char *destination, uint32_t mode);
/* Prepare an owned entry for deletion, without following symbolic links. */
int32_t rift_prepare_removal(const char *path);
int32_t rift_remove_path(const char *path, int32_t directory);
struct rift_metadata_error rift_copy_metadata(const char *source, const char *destination);

/* Native clone tracking is optional on older macOS/APFS versions. */
int32_t rift_clone_identifier(const char *path, uint64_t *identifier);

#endif
