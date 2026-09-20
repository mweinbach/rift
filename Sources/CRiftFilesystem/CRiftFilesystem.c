#include "CRiftFilesystem.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

static struct rift_metadata_error metadata_error(const char *operation, int source_path) {
    struct rift_metadata_error error = {errno, operation, source_path};
    return error;
}

int32_t rift_read_file_info(const char *path, struct rift_file_info *info) {
    struct stat metadata;
    if (lstat(path, &metadata) != 0) return errno;
    info->device = (uint64_t)metadata.st_dev;
    info->inode = metadata.st_ino;
    info->link_count = metadata.st_nlink;
    info->mode = metadata.st_mode & 07777;
    info->flags = metadata.st_flags;
    info->type = S_ISDIR(metadata.st_mode) ? RIFT_ENTRY_DIRECTORY :
        S_ISREG(metadata.st_mode) ? RIFT_ENTRY_FILE :
        S_ISLNK(metadata.st_mode) ? RIFT_ENTRY_SYMLINK : RIFT_ENTRY_UNSUPPORTED;
    return 0;
}

int32_t rift_clone_path(const char *source, const char *destination) {
    /* clonefile is the only data-copy operation: no byte-copy fallback. */
    return clonefile(source, destination, CLONE_NOFOLLOW) == 0 ? 0 : errno;
}

int32_t rift_create_directory(const char *path) {
    /* Keep fresh directories writable until their children and metadata exist. */
    return mkdir(path, 0700) == 0 ? 0 : errno;
}

int32_t rift_create_hard_link(const char *existing, const char *destination) {
    struct stat metadata;
    if (lstat(existing, &metadata) != 0) return errno;
    uint32_t blocking_flags = UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND;
    int cleared_flags = (metadata.st_flags & blocking_flags) != 0;
    if (cleared_flags && lchflags(existing, metadata.st_flags & ~blocking_flags) != 0) {
        return errno;
    }
    int32_t error = link(existing, destination) == 0 ? 0 : errno;
    if (cleared_flags && lchflags(existing, metadata.st_flags) != 0 && error == 0) {
        error = errno;
    }
    return error;
}

int32_t rift_copy_symlink(const char *source, const char *destination) {
    size_t capacity = 256;
    for (;;) {
        char *target = malloc(capacity + 1);
        if (target == NULL) return ENOMEM;
        ssize_t length = readlink(source, target, capacity);
        if (length < 0) {
            int32_t error = errno;
            free(target);
            return error;
        }
        if ((size_t)length < capacity) {
            target[length] = '\0';
            int32_t error = symlink(target, destination) == 0 ? 0 : errno;
            free(target);
            return error;
        }
        free(target);
        if (capacity > SIZE_MAX / 2 - 1) return ENAMETOOLONG;
        capacity *= 2;
    }
}

int32_t rift_restore_cloned_file_mode(const char *destination, uint32_t mode) {
    struct stat metadata;
    if (lstat(destination, &metadata) != 0) return errno;
    if (!S_ISREG(metadata.st_mode)) return EINVAL;
    uint32_t blocking_flags = UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND;
    int cleared_flags = (metadata.st_flags & blocking_flags) != 0;
    if (cleared_flags && lchflags(destination, metadata.st_flags & ~blocking_flags) != 0) {
        return errno;
    }
    /* Clones already carry xattrs, ownership, and times. Replaying these would
       fail on read-only Git objects and protected com.apple.provenance attrs. */
    int32_t error = chmod(destination, (mode_t)mode) == 0 ? 0 : errno;
    if (cleared_flags && lchflags(destination, metadata.st_flags) != 0 && error == 0) {
        error = errno;
    }
    return error;
}

int32_t rift_prepare_removal(const char *path) {
    struct stat metadata;
    if (lstat(path, &metadata) != 0) return errno;
    uint32_t blocking_flags = UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND;
    if ((metadata.st_flags & blocking_flags) != 0 &&
        lchflags(path, metadata.st_flags & ~blocking_flags) != 0) {
        return errno;
    }
    /* Deleting children requires writable, searchable directories. lchmod
       never changes a symlink target, unlike chmod. Preserve other mode bits. */
    if (S_ISDIR(metadata.st_mode) && (metadata.st_mode & 0700) != 0700 &&
        lchmod(path, (metadata.st_mode & 07777) | 0700) != 0) {
        return errno;
    }
    return 0;
}

int32_t rift_remove_path(const char *path, int32_t directory) {
    int result = directory ? rmdir(path) : unlink(path);
    return result == 0 ? 0 : errno;
}

static struct rift_metadata_error copy_xattrs(const char *source, const char *destination) {
    char *names = NULL;
    ssize_t names_length;
    for (;;) {
        ssize_t capacity = listxattr(source, NULL, 0, XATTR_NOFOLLOW);
        if (capacity < 0) return metadata_error("read extended attributes", 1);
        if (capacity == 0) return (struct rift_metadata_error){0, NULL, 0};
        names = malloc((size_t)capacity);
        if (names == NULL) {
            errno = ENOMEM;
            return metadata_error("read extended attributes", 1);
        }
        names_length = listxattr(source, names, (size_t)capacity, XATTR_NOFOLLOW);
        if (names_length >= 0) break;
        int error = errno;
        free(names);
        if (error == ERANGE) continue;
        errno = error;
        return metadata_error("read extended attributes", 1);
    }

    for (ssize_t offset = 0; offset < names_length;) {
        const char *name = names + offset;
        size_t name_length = strnlen(name, (size_t)(names_length - offset));
        if (name_length == (size_t)(names_length - offset)) {
            free(names);
            errno = EIO;
            return metadata_error("read extended attributes", 1);
        }
        offset += (ssize_t)name_length + 1;
        void *value = NULL;
        ssize_t value_length;
        for (;;) {
            ssize_t capacity = getxattr(source, name, NULL, 0, 0, XATTR_NOFOLLOW);
            if (capacity < 0) {
                struct rift_metadata_error error = metadata_error("read extended attribute", 1);
                free(names);
                return error;
            }
            value = malloc(capacity == 0 ? 1 : (size_t)capacity);
            if (value == NULL) {
                free(names);
                errno = ENOMEM;
                return metadata_error("read extended attribute", 1);
            }
            value_length = getxattr(source, name, value, (size_t)capacity, 0, XATTR_NOFOLLOW);
            if (value_length >= 0 && value_length <= capacity) break;
            /* A zero-size getxattr is a probe even with a non-null buffer. */
            if (value_length > capacity) {
                free(value);
                continue;
            }
            int error = errno;
            free(value);
            if (error == ERANGE) continue;
            free(names);
            errno = error;
            return metadata_error("read extended attribute", 1);
        }
        if (setxattr(destination, name, value, (size_t)value_length, 0, XATTR_NOFOLLOW) != 0) {
            struct rift_metadata_error error = metadata_error("set extended attribute", 0);
            free(value);
            free(names);
            return error;
        }
        free(value);
    }
    free(names);
    return (struct rift_metadata_error){0, NULL, 0};
}

struct rift_metadata_error rift_copy_metadata(const char *source, const char *destination) {
    struct stat metadata;
    if (lstat(source, &metadata) != 0) return metadata_error("read metadata", 1);
    /* Assigning a foreign uid/gid requires privileges; match upstream's
       best-effort ownership policy while surfacing every other error. */
    if (lchown(destination, metadata.st_uid, metadata.st_gid) != 0 && errno != EPERM) {
        return metadata_error("change ownership", 0);
    }
    struct rift_metadata_error error = copy_xattrs(source, destination);
    if (error.code != 0) return error;

    if (!S_ISLNK(metadata.st_mode) && chmod(destination, metadata.st_mode & 07777) != 0) {
        return metadata_error("set permissions", 0);
    }
    /* Set creation time separately; ctime is kernel-managed and cannot be
       replayed. NOFOLLOW keeps dangling symlink metadata independent. */
    struct attrlist attributes = {0};
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_CRTIME;
    struct timespec creation_time = metadata.st_birthtimespec;
    if (setattrlist(destination, &attributes, &creation_time, sizeof(creation_time), FSOPT_NOFOLLOW) != 0) {
        return metadata_error("set creation time", 0);
    }
    struct timespec times[2] = {metadata.st_atimespec, metadata.st_mtimespec};
    if (utimensat(AT_FDCWD, destination, times, AT_SYMLINK_NOFOLLOW) != 0) {
        return metadata_error("set timestamps", 0);
    }
    /* Flags such as immutable/append must be applied after all writes. */
    if (lchflags(destination, metadata.st_flags) != 0) {
        return metadata_error("set file flags", 0);
    }
    return (struct rift_metadata_error){0, NULL, 0};
}

int32_t rift_clone_identifier(const char *path, uint64_t *identifier) {
    struct attrlist attributes = {0};
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_RETURNED_ATTRS;
    attributes.forkattr = ATTR_CMNEXT_CLONEID;
    unsigned char buffer[sizeof(uint32_t) + sizeof(attribute_set_t) + sizeof(uint64_t)] = {0};
    if (getattrlist(path, &attributes, buffer, sizeof(buffer), FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW) != 0) {
        return errno;
    }
    uint32_t length;
    attribute_set_t returned;
    memcpy(&length, buffer, sizeof(length));
    memcpy(&returned, buffer + sizeof(length), sizeof(returned));
    if (length != sizeof(buffer) || (returned.forkattr & ATTR_CMNEXT_CLONEID) == 0) return ENOTSUP;
    memcpy(identifier, buffer + sizeof(length) + sizeof(returned), sizeof(*identifier));
    return 0;
}
