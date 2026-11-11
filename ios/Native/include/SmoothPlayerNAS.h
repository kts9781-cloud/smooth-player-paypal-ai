#ifndef SMOOTH_PLAYER_NAS_H
#define SMOOTH_PLAYER_NAS_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct sp_nas_client sp_nas_client;
typedef struct sp_nas_file sp_nas_file;
enum { SP_NAS_SMB = 1, SP_NAS_FTP = 2 };
enum { SP_NAS_OK = 0, SP_NAS_IO = -1, SP_NAS_AUTH = -2, SP_NAS_TIMEOUT = -3,
       SP_NAS_INVALID = -4, SP_NAS_CLOSED = -5, SP_NAS_LIMIT = -6, SP_NAS_ENCODING = -7 };
enum { SP_FTP_AUTO = 0, SP_FTP_UTF8 = 1, SP_FTP_CP949 = 2, SP_FTP_EUC_KR = 3 };
typedef void (*sp_nas_path_entry_callback)(void *context, const char *name, const char *encoded_path,
                                         int is_directory, uint64_t size, int64_t modified_unix);
typedef void (*sp_nas_entry_callback)(void *context, const char *name, int is_directory,
                                    uint64_t size, int64_t modified_unix);
typedef void (*sp_nas_share_callback)(void *context, const char *name);
// Opens an independent IPC$ session; reports visible disk shares only, never printer/IPC/hidden shares.
int sp_nas_list_shares(const char *host, uint16_t port, const char *user, const char *password,
                       const char *domain, int timeout_seconds, sp_nas_share_callback callback, void *context);
// Each client and its file handles must be confined to one serial queue. No function logs credentials or URLs.
sp_nas_client *sp_nas_connect(int protocol, const char *host, uint16_t port, const char *share,
                             const char *user, const char *password, const char *domain,
                             int timeout_seconds, int *status);
void sp_nas_disconnect(sp_nas_client *client);
int sp_nas_set_ftp_encoding(sp_nas_client *client, int encoding);
// encoded_path is an opaque percent-encoded original-byte path returned by list_paths.
// Pass NULL for a manually entered root. Keep it alongside display names for child operations.
int sp_nas_list_paths(sp_nas_client *client, const char *path, const char *encoded_path,
                     sp_nas_path_entry_callback callback, void *context);
sp_nas_file *sp_nas_open_path(sp_nas_client *client, const char *path, const char *encoded_path,
                            int64_t *size, int *status);
// expected_size is a size from the current server listing, or -1 if unavailable.
// A fresh protocol-reported size takes precedence; the hint only covers FTP servers without SIZE.
sp_nas_file *sp_nas_open_path_with_size(sp_nas_client *client, const char *path, const char *encoded_path,
                                      int64_t expected_size, int64_t *size, int *status);
int sp_nas_list(sp_nas_client *client, const char *path, sp_nas_entry_callback callback, void *context);
sp_nas_file *sp_nas_open(sp_nas_client *client, const char *path, int64_t *size, int *status);
// Returns up to count bytes. A successful short read is not EOF; advance by the
// returned count and continue. A no-progress timeout still returns SP_NAS_TIMEOUT.
int sp_nas_read(sp_nas_file *file, int64_t offset, uint8_t *buffer, uint32_t count);
void sp_nas_close(sp_nas_file *file);
#ifdef __cplusplus
}
#endif
#endif
