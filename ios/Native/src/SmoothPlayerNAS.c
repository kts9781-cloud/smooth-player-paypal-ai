#include "SmoothPlayerNAS.h"
#include <CFNetwork/CFNetwork.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>

#define MAX_READ (1024u * 1024u)
#define MAX_LIST (8u * 1024u * 1024u)
#define MAX_ENTRIES 10000
#define MAX_WIRE_PATH (8192 * 3 + 1)

struct sp_nas_client {
    int protocol;
    int timeout;
    int ftp_encoding;
    struct smb2_context *smb;
    CFStringRef ftp_base;
    CFStringRef user;
    CFStringRef password;
};
struct sp_nas_file {
    sp_nas_client *client;
    struct smb2fh *smb;
    char *path;
    char *wire_path;
    int64_t size;
    CFReadStreamRef ftp_stream;
    CFOptionFlags ftp_events;
    int64_t ftp_offset;
};

struct smb_result { int done; int status; void *data; };
static void smb_result_cb(struct smb2_context *smb, int status, void *data, void *context) {
    (void)smb;
    struct smb_result *result = context;
    result->status = status; result->data = data; result->done = 1;
}
static void smb_abandon(sp_nas_client *client) {
    struct smb2_context *context = client->smb;
    client->smb = NULL;
    // Destruction completes pending callbacks synchronously and frees all file handles.
    if (context) smb2_destroy_context(context);
}
static int smb_wait(sp_nas_client *client, struct smb_result *result) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + client->timeout;
    while (!result->done) {
        if (CFAbsoluteTimeGetCurrent() >= deadline) { smb_abandon(client); return SP_NAS_TIMEOUT; }
        struct pollfd fd = { .fd = smb2_get_fd(client->smb), .events = (short)smb2_which_events(client->smb) };
        int ready = poll(&fd, 1, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || (ready > 0 && smb2_service(client->smb, fd.revents) < 0)) {
            smb_abandon(client); return SP_NAS_IO;
        }
    }
    if (result->status == -EACCES) return SP_NAS_AUTH;
    return result->status < 0 ? SP_NAS_IO : result->status;
}

static int valid_path(const char *path) {
    if (!path || strlen(path) > 8192 || strchr(path, '\\') || strchr(path, '\r') || strchr(path, '\n')) return 0;
    const char *part = path;
    while (*part) {
        while (*part == '/') part++;
        const char *end = strchr(part, '/');
        size_t length = end ? (size_t)(end - part) : strlen(part);
        if (length == 2 && part[0] == '.' && part[1] == '.') return 0;
        if (!end) break;
        part = end + 1;
    }
    return 1;
}
static int safe_name(const char *name) {
    return name && *name && strcmp(name, ".") && strcmp(name, "..") &&
        !strchr(name, '/') && !strchr(name, '\\') && !strchr(name, '\r') && !strchr(name, '\n');
}
static CFStringRef string(const char *value) {
    return CFStringCreateWithCString(kCFAllocatorDefault, value ? value : "", kCFStringEncodingUTF8);
}
static CFStringEncoding ftp_encoding(int setting) {
    switch (setting) {
        case SP_FTP_CP949: return kCFStringEncodingDOSKorean;
        case SP_FTP_EUC_KR: return kCFStringEncodingEUC_KR;
        default: return kCFStringEncodingUTF8;
    }
}

static int encode_bytes(CFStringRef value, CFStringEncoding encoding, UInt8 *bytes, CFIndex capacity, CFIndex *used) {
    CFIndex length = CFStringGetLength(value);
    return CFStringGetBytes(value, CFRangeMake(0, length), encoding, 0, false, bytes, capacity, used) == length;
}

static char *escape_path_bytes(const UInt8 *bytes, size_t length) {
    if (length > 8192) return NULL;
    char *escaped = malloc(length * 3 + 1);
    if (!escaped) return NULL;
    const char hex[] = "0123456789ABCDEF";
    size_t out = 0;
    for (size_t i = 0; i < length; i++) {
        UInt8 c = bytes[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '/' || c == '-' || c == '_' || c == '.' || c == '~') escaped[out++] = (char)c;
        else { escaped[out++] = '%'; escaped[out++] = hex[c >> 4]; escaped[out++] = hex[c & 15]; }
    }
    escaped[out] = 0;
    return escaped;
}
static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static int valid_wire_path(const char *path) {
    if (!path || path[0] != '/' || strlen(path) >= MAX_WIRE_PATH) return 0;
    char decoded[8193]; size_t out = 0;
    for (size_t i = 0; path[i]; i++) {
        unsigned char c = (unsigned char)path[i];
        if (c == '%') {
            if (!path[i + 1] || !path[i + 2]) return 0;
            int hi = hex_value(path[i + 1]), lo = hex_value(path[i + 2]);
            if (hi < 0 || lo < 0) return 0;
            c = (unsigned char)((hi << 4) | lo); i += 2;
            if (!c || c == '/' || c == '\\' || c == '\r' || c == '\n') return 0;
        } else if (c > 127 || !(c == '/' || c == '-' || c == '_' || c == '.' || c == '~' ||
                   (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return 0;
        if (out >= 8192) return 0;
        decoded[out++] = (char)c;
    }
    decoded[out] = 0;
    return valid_path(decoded);
}
static char *wire_path_from_display(sp_nas_client *client, const char *path) {
    CFStringRef raw = string(path);
    if (!raw) return NULL;
    UInt8 bytes[8192]; CFIndex used = 0;
    int ok = encode_bytes(raw, ftp_encoding(client->ftp_encoding), bytes, sizeof(bytes), &used);
    CFRelease(raw);
    if (!ok) return NULL;
    char *escaped = escape_path_bytes(bytes, (size_t)used);
    if (escaped && escaped[0] != '/') {
        size_t length = strlen(escaped);
        char *absolute = malloc(length + 2);
        if (absolute) { absolute[0] = '/'; memcpy(absolute + 1, escaped, length + 1); }
        free(escaped); escaped = absolute;
    }
    return escaped;
}
static CFURLRef ftp_url(sp_nas_client *client, const char *path, const char *wire_path, int directory) {
    char *owned = wire_path ? NULL : wire_path_from_display(client, path);
    const char *encoded = wire_path ? wire_path : owned;
    if (!valid_wire_path(encoded)) { free(owned); return NULL; }
    CFStringRef escaped = string(encoded);
    free(owned);
    if (!escaped) return NULL;
    CFMutableStringRef full = CFStringCreateMutableCopy(NULL, 0, client->ftp_base);
    CFStringAppend(full, escaped);
    if (directory && !CFStringHasSuffix(full, CFSTR("/"))) CFStringAppend(full, CFSTR("/"));
    CFURLRef result = CFURLCreateWithString(NULL, full, NULL);
    CFRelease(full); CFRelease(escaped);
    return result;
}
static void stream_event(CFReadStreamRef stream, CFStreamEventType event, void *info) {
    (void)stream; *(CFOptionFlags *)info |= event;
}
static int stream_error(CFReadStreamRef stream) {
    CFStreamError error = CFReadStreamGetError(stream);
    if (error.domain == kCFStreamErrorDomainFTP && (error.error == 530 || error.error == 532)) return SP_NAS_AUTH;
    return SP_NAS_IO;
}

static int contains_bytes(const UInt8 *record, size_t length, const UInt8 *name, size_t count) {
    if (!count || count > length) return 0;
    for (size_t i = 0; i + count <= length; i++) if (!memcmp(record + i, name, count)) return 1;
    return 0;
}
static int ftp_name_bytes(CFStringRef name, const UInt8 *record, size_t record_length, UInt8 *raw, CFIndex *used) {
    // Apple SimpleFTPSample documents that CFFTP's LIST parser interprets names as
    // MacRoman. This inverse is lossless and is accepted only when those exact bytes
    // occur in the consumed wire record; never repair a guessed mojibake string.
    if (encode_bytes(name, kCFStringEncodingMacRoman, raw, 8192, used) &&
        contains_bytes(record, record_length, raw, (size_t)*used)) return 1;
    // A parser that already returned Unicode is accepted only with exact wire evidence.
    return encode_bytes(name, kCFStringEncodingUTF8, raw, 8192, used) &&
        contains_bytes(record, record_length, raw, (size_t)*used);
}
static int decode_name(const UInt8 *raw, CFIndex length, CFStringEncoding encoding, char *output, size_t capacity) {
    CFStringRef decoded = CFStringCreateWithBytes(NULL, raw, length, encoding, false);
    if (!decoded) return 0;
    UInt8 roundtrip[8192]; CFIndex used = 0;
    int ok = encode_bytes(decoded, encoding, roundtrip, sizeof(roundtrip), &used) && used == length &&
        !memcmp(raw, roundtrip, (size_t)length) && CFStringGetCString(decoded, output, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(decoded);
    return ok;
}
static int ftp_name_utf8(sp_nas_client *client, const UInt8 *raw, CFIndex length, char *output, size_t capacity) {
    if (client->ftp_encoding != SP_FTP_AUTO) return decode_name(raw, length, ftp_encoding(client->ftp_encoding), output, capacity);
    // UTF-8 is strict; CP949 also covers ordinary EUC-KR. Every fallback must encode
    // back byte-for-byte. The explicit server setting resolves ambiguous legacy names.
    return decode_name(raw, length, kCFStringEncodingUTF8, output, capacity) ||
           decode_name(raw, length, kCFStringEncodingDOSKorean, output, capacity);
}
static char *wire_child(const char *parent, const UInt8 *name, size_t length) {
    if (!valid_wire_path(parent) || !length || memchr(name, 0, length) || memchr(name, '/', length) ||
        memchr(name, '\\', length) || memchr(name, '\r', length) || memchr(name, '\n', length)) return NULL;
    char *escaped = escape_path_bytes(name, length);
    if (!escaped) return NULL;
    size_t parent_length = strlen(parent), name_length = strlen(escaped);
    while (parent_length > 1 && parent[parent_length - 1] == '/') parent_length--;
    size_t separator = parent_length > 1 ? 1 : 0;
    char *result = malloc(parent_length + separator + name_length + 1);
    if (result) {
        memcpy(result, parent, parent_length);
        if (separator) result[parent_length] = '/';
        memcpy(result + parent_length + separator, escaped, name_length + 1);
        if (!valid_wire_path(result)) { free(result); result = NULL; }
    }
    free(escaped); return result;
}

// A bounded REST transfer per read keeps seeking independent of previous buffering and confines CFRunLoop use
// to the calling serial operation. Credentials are stream properties, never URL components or diagnostics.
static int ftp_transfer(sp_nas_client *client, const char *path, const char *wire_path, int directory, int64_t offset,
                        uint8_t *output, uint32_t capacity, int64_t *resource_size) {
    CFURLRef url = ftp_url(client, path, wire_path, directory);
    if (!url) return SP_NAS_INVALID;
    CFReadStreamRef stream = CFReadStreamCreateWithFTPURL(NULL, url);
    CFRelease(url);
    if (!stream) return SP_NAS_IO;
    CFReadStreamSetProperty(stream, kCFStreamPropertyFTPUserName, client->user);
    CFReadStreamSetProperty(stream, kCFStreamPropertyFTPPassword, client->password);
    CFReadStreamSetProperty(stream, kCFStreamPropertyFTPUsePassiveMode, kCFBooleanTrue);
    CFReadStreamSetProperty(stream, kCFStreamPropertyFTPFetchResourceInfo, kCFBooleanTrue);
    CFReadStreamSetProperty(stream, kCFStreamPropertyFTPAttemptPersistentConnection, kCFBooleanFalse);
    if (offset > 0) {
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &offset);
        Boolean accepted = CFReadStreamSetProperty(stream, kCFStreamPropertyFTPFileTransferOffset, number);
        CFRelease(number);
        if (!accepted) { CFRelease(stream); return SP_NAS_INVALID; }
    }
    CFOptionFlags events = 0;
    CFStreamClientContext context = {0, &events, NULL, NULL, NULL};
    CFReadStreamSetClient(stream, kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable |
                          kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, stream_event, &context);
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    CFReadStreamScheduleWithRunLoop(stream, loop, kCFRunLoopDefaultMode);
    int result = SP_NAS_IO;
    if (CFReadStreamOpen(stream)) {
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + client->timeout;
        uint32_t total = 0;
        while (1) {
            // The deadline applies even while a server keeps trickling bytes.
            // Checking only the no-data branch can leave a long read running.
            if (CFAbsoluteTimeGetCurrent() >= deadline) { result = SP_NAS_TIMEOUT; break; }
            CFStreamStatus status = CFReadStreamGetStatus(stream);
            if (status == kCFStreamStatusError || (events & kCFStreamEventErrorOccurred)) { result = stream_error(stream); break; }
            if (CFReadStreamHasBytesAvailable(stream)) {
                if (total == capacity) { result = directory ? SP_NAS_LIMIT : (int)total; break; }
                CFIndex n = CFReadStreamRead(stream, output + total, capacity - total);
                if (n < 0) { result = stream_error(stream); break; }
                if (n == 0) { result = (int)total; break; }
                total += (uint32_t)n;
                if (!directory && total == capacity) { result = (int)total; break; }
            } else if (status == kCFStreamStatusAtEnd || (events & kCFStreamEventEndEncountered)) {
                result = (int)total; break;
            } else {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
        }
        if (resource_size) {
            CFTypeRef value = CFReadStreamCopyProperty(stream, kCFStreamPropertyFTPResourceSize);
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt64Type, resource_size);
            if (value) CFRelease(value);
        }
    }
    CFReadStreamClose(stream);
    CFReadStreamUnscheduleFromRunLoop(stream, loop, kCFRunLoopDefaultMode);
    CFReadStreamSetClient(stream, 0, NULL, NULL);
    CFRelease(stream);
    return result;
}

static void ftp_close_file_stream(sp_nas_file *file) {
    if (!file->ftp_stream) return;
    CFReadStreamClose(file->ftp_stream);
    CFReadStreamSetClient(file->ftp_stream, 0, NULL, NULL);
    CFRelease(file->ftp_stream);
    file->ftp_stream = NULL;
    file->ftp_events = 0;
}

// Keep a sequential RETR alive across bounded reads. Random seeks alone reopen
// with REST. A serial dispatch queue can use different worker threads, so every
// operation schedules/unschedules the stream on its own current run loop.
static int ftp_read_file(sp_nas_file *file, int64_t offset, uint8_t *output, uint32_t capacity) {
    sp_nas_client *client = file->client;
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    if (file->ftp_stream && offset != file->ftp_offset) ftp_close_file_stream(file);
    int opening = file->ftp_stream == NULL;
    if (opening) {
        CFURLRef url = ftp_url(client, file->path, file->wire_path, 0);
        if (!url) return SP_NAS_INVALID;
        file->ftp_stream = CFReadStreamCreateWithFTPURL(NULL, url);
        CFRelease(url);
        if (!file->ftp_stream) return SP_NAS_IO;
        CFReadStreamSetProperty(file->ftp_stream, kCFStreamPropertyFTPUserName, client->user);
        CFReadStreamSetProperty(file->ftp_stream, kCFStreamPropertyFTPPassword, client->password);
        CFReadStreamSetProperty(file->ftp_stream, kCFStreamPropertyFTPUsePassiveMode, kCFBooleanTrue);
        // File size was established by open (or the selected listing); do not
        // require SIZE again, because some otherwise valid servers omit it.
        CFReadStreamSetProperty(file->ftp_stream, kCFStreamPropertyFTPFetchResourceInfo, kCFBooleanFalse);
        CFReadStreamSetProperty(file->ftp_stream, kCFStreamPropertyFTPAttemptPersistentConnection, kCFBooleanFalse);
        if (offset > 0) {
            CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &offset);
            Boolean accepted = CFReadStreamSetProperty(file->ftp_stream, kCFStreamPropertyFTPFileTransferOffset, number);
            CFRelease(number);
            if (!accepted) { ftp_close_file_stream(file); return SP_NAS_INVALID; }
        }
        file->ftp_offset = offset;
        file->ftp_events = 0;
        CFStreamClientContext context = {0, &file->ftp_events, NULL, NULL, NULL};
        if (!CFReadStreamSetClient(file->ftp_stream, kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable |
                                  kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, stream_event, &context)) {
            ftp_close_file_stream(file); return SP_NAS_IO;
        }
    }
    CFReadStreamScheduleWithRunLoop(file->ftp_stream, loop, kCFRunLoopDefaultMode);
    int result = SP_NAS_IO;
    uint32_t total = 0;
    if (!opening || CFReadStreamOpen(file->ftp_stream)) {
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + client->timeout;
        while (1) {
            if (CFAbsoluteTimeGetCurrent() >= deadline) {
                result = total ? (int)total : SP_NAS_TIMEOUT;
                break;
            }
            CFStreamStatus status = CFReadStreamGetStatus(file->ftp_stream);
            if (status == kCFStreamStatusError || (file->ftp_events & kCFStreamEventErrorOccurred)) {
                result = stream_error(file->ftp_stream); break;
            }
            if (CFReadStreamHasBytesAvailable(file->ftp_stream)) {
                CFIndex count = CFReadStreamRead(file->ftp_stream, output + total, capacity - total);
                if (count < 0) { result = stream_error(file->ftp_stream); break; }
                if (count == 0) { result = (int)total; break; }
                total += (uint32_t)count;
                if (total == capacity) { result = (int)total; break; }
            } else if (status == kCFStreamStatusAtEnd || (file->ftp_events & kCFStreamEventEndEncountered)) {
                result = (int)total; break;
            } else if (total > 0) {
                // capacity is an upper bound, not a minimum transfer size.
                // Hand a completed burst to the decoder before waiting for the
                // rest of its 1 MiB cache window. Keep RETR open at this offset
                // so the next demand/prefetch read continues the same transfer.
                result = (int)total; break;
            } else {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
        }
    }
    CFReadStreamUnscheduleFromRunLoop(file->ftp_stream, loop, kCFRunLoopDefaultMode);
    if (result < 0 || result == 0) ftp_close_file_stream(file);
    else file->ftp_offset += result;
    return result;
}

sp_nas_client *sp_nas_connect(int protocol, const char *host, uint16_t port, const char *share,
                             const char *user, const char *password, const char *domain,
                             int timeout_seconds, int *status) {
    if (status) *status = SP_NAS_INVALID;
    if (!host || !*host || strlen(host) > 253 || strpbrk(host, "/@?# \r\n\t") || !port ||
        (protocol != SP_NAS_SMB && protocol != SP_NAS_FTP)) return NULL;
    sp_nas_client *client = calloc(1, sizeof(*client));
    if (!client) { if (status) *status = SP_NAS_IO; return NULL; }
    client->protocol = protocol;
    client->timeout = timeout_seconds < 1 ? 8 : (timeout_seconds > 30 ? 30 : timeout_seconds);
    if (protocol == SP_NAS_SMB) {
        if (!share || !*share || strpbrk(share, "/\\\r\n")) goto invalid;
        client->smb = smb2_init_context();
        if (!client->smb) goto failure;
        smb2_set_timeout(client->smb, client->timeout);
        smb2_set_security_mode(client->smb, SMB2_NEGOTIATE_SIGNING_ENABLED);
        smb2_set_user(client->smb, user ? user : "");
        smb2_set_password(client->smb, password ? password : "");
        if (domain && *domain) smb2_set_domain(client->smb, domain);
        char server[300];
        snprintf(server, sizeof(server), strchr(host, ':') ? "[%s]:%u" : "%s:%u", host, (unsigned)port);
        struct smb_result result = {0};
        if (smb2_connect_share_async(client->smb, server, share, user && *user ? user : NULL, smb_result_cb, &result) < 0) goto failure;
        int connected = smb_wait(client, &result);
        if (connected < 0) {
            if (status) *status = connected;
            sp_nas_disconnect(client); return NULL;
        }
    } else {
        char base[320];
        snprintf(base, sizeof(base), strchr(host, ':') ? "ftp://[%s]:%u" : "ftp://%s:%u", host, (unsigned)port);
        client->ftp_base = string(base);
        client->user = string(user && *user ? user : "anonymous");
        client->password = string(password);
        if (!client->ftp_base || !client->user || !client->password) goto failure;
    }
    if (status) *status = SP_NAS_OK;
    return client;
invalid:
    if (status) *status = SP_NAS_INVALID;
    sp_nas_disconnect(client); return NULL;
failure:
    if (status) *status = SP_NAS_IO;
    sp_nas_disconnect(client); return NULL;
}

void sp_nas_disconnect(sp_nas_client *client) {
    if (!client) return;
    if (client->smb) smb2_destroy_context(client->smb);
    if (client->ftp_base) CFRelease(client->ftp_base);
    if (client->user) CFRelease(client->user);
    if (client->password) CFRelease(client->password);
    free(client);
}

int sp_nas_list_shares(const char *host, uint16_t port, const char *user, const char *password,
                       const char *domain, int timeout_seconds, sp_nas_share_callback callback, void *context) {
    if (!callback) return SP_NAS_INVALID;
    int status = 0;
    sp_nas_client *client = sp_nas_connect(SP_NAS_SMB, host, port, "IPC$", user, password, domain, timeout_seconds, &status);
    if (!client) return status;
    struct smb_result result = {0};
    if (smb2_share_enum_async(client->smb, SHARE_INFO_1, smb_result_cb, &result) < 0) status = SP_NAS_IO;
    else status = smb_wait(client, &result);
    struct srvsvc_NetrShareEnum_rep *reply = result.data;
    if (status == 0 && reply) {
        const struct srvsvc_SHARE_INFO_1_CONTAINER *list = &reply->ses.ShareInfo.Level1;
        if (reply->status != 0) status = reply->status == 5 ? SP_NAS_AUTH : SP_NAS_IO;
        else if (list->EntriesRead > MAX_ENTRIES) status = SP_NAS_LIMIT;
        else if (list->EntriesRead && (!list->Buffer || !list->Buffer->share_info_1)) status = SP_NAS_IO;
        else for (uint32_t i = 0; i < list->EntriesRead; i++) {
            const struct srvsvc_SHARE_INFO_1 *share = &list->Buffer->share_info_1[i];
            if ((share->type & 3) == SHARE_TYPE_DISKTREE && !(share->type & SHARE_TYPE_HIDDEN) &&
                safe_name(share->netname.utf8) && strlen(share->netname.utf8) <= 255 &&
                share->netname.utf8[strlen(share->netname.utf8) - 1] != '$')
                callback(context, share->netname.utf8);
        }
    } else if (status == 0) status = SP_NAS_IO;
    if (reply && client->smb) smb2_free_data(client->smb, reply);
    sp_nas_disconnect(client);
    return status;
}

static int list_internal(sp_nas_client *client, const char *path, const char *wire_path,
                         sp_nas_entry_callback callback, sp_nas_path_entry_callback path_callback, void *context) {
    if (!client || (!callback && !path_callback) || !valid_path(path) || (wire_path && !valid_wire_path(wire_path))) return SP_NAS_INVALID;
    int count = 0;
    if (client->protocol == SP_NAS_SMB) {
        if (!client->smb) return SP_NAS_CLOSED;
        while (*path == '/') path++;
        struct smb_result result = {0};
        if (smb2_opendir_async(client->smb, path, smb_result_cb, &result) < 0) return SP_NAS_IO;
        int status = smb_wait(client, &result);
        if (status < 0) return status;
        struct smb2dir *dir = result.data;
        if (!dir) return SP_NAS_IO;
        struct smb2dirent *entry;
        while ((entry = smb2_readdir(client->smb, dir))) {
            if (!safe_name(entry->name)) continue;
            if (++count > MAX_ENTRIES) { smb2_closedir(client->smb, dir); return SP_NAS_LIMIT; }
            if (callback) callback(context, entry->name, entry->st.smb2_type == SMB2_TYPE_DIRECTORY,
                                   entry->st.smb2_size, (int64_t)entry->st.smb2_mtime);
            if (path_callback) path_callback(context, entry->name, NULL, entry->st.smb2_type == SMB2_TYPE_DIRECTORY,
                                            entry->st.smb2_size, (int64_t)entry->st.smb2_mtime);
        }
        smb2_closedir(client->smb, dir);
    } else {
        uint8_t *bytes = malloc(MAX_LIST);
        if (!bytes) return SP_NAS_IO;
        int length = ftp_transfer(client, path, wire_path, 1, 0, bytes, MAX_LIST, NULL);
        if (length < 0) { free(bytes); return length; }
        CFIndex cursor = 0;
        while (cursor < length) {
            CFDictionaryRef item = NULL;
            CFIndex consumed = CFFTPCreateParsedResourceListing(NULL, bytes + cursor, length - cursor, &item);
            if (consumed <= 0) { if (item) CFRelease(item); free(bytes); return SP_NAS_IO; }
            const UInt8 *record = bytes + cursor;
            cursor += consumed;
            if (!item) continue;
            CFStringRef name = CFDictionaryGetValue(item, kCFFTPResourceName);
            CFNumberRef type = CFDictionaryGetValue(item, kCFFTPResourceType);
            CFNumberRef size = CFDictionaryGetValue(item, kCFFTPResourceSize);
            CFDateRef modified = CFDictionaryGetValue(item, kCFFTPResourceModDate);
            char utf8[8192]; int kind = 0; int64_t file_size = 0;
            if (type) CFNumberGetValue(type, kCFNumberIntType, &kind);
            if (size) CFNumberGetValue(size, kCFNumberSInt64Type, &file_size);
            UInt8 raw_name[8192]; CFIndex raw_length = 0;
            if (name && (!ftp_name_bytes(name, record, (size_t)consumed, raw_name, &raw_length) ||
                         !ftp_name_utf8(client, raw_name, raw_length, utf8, sizeof(utf8)))) {
                CFRelease(item); free(bytes); return SP_NAS_ENCODING;
            }
            if (name && safe_name(utf8)) {
                if (++count > MAX_ENTRIES) { CFRelease(item); free(bytes); return SP_NAS_LIMIT; }
                int64_t unix_time = modified ? (int64_t)(CFDateGetAbsoluteTime(modified) + kCFAbsoluteTimeIntervalSince1970) : 0;
                if (callback) callback(context, utf8, kind == 4, file_size > 0 ? (uint64_t)file_size : 0, unix_time);
                if (path_callback) {
                    char *parent = wire_path ? strdup(wire_path) : wire_path_from_display(client, path);
                    char *child = parent ? wire_child(parent, raw_name, (size_t)raw_length) : NULL;
                    free(parent);
                    if (!child) { CFRelease(item); free(bytes); return SP_NAS_INVALID; }
                    path_callback(context, utf8, child, kind == 4, file_size > 0 ? (uint64_t)file_size : 0, unix_time);
                    free(child);
                }
            }
            CFRelease(item);
        }
        free(bytes);
    }
    return SP_NAS_OK;
}

int sp_nas_set_ftp_encoding(sp_nas_client *client, int encoding) {
    if (!client || encoding < SP_FTP_AUTO || encoding > SP_FTP_EUC_KR) return SP_NAS_INVALID;
    client->ftp_encoding = encoding;
    return SP_NAS_OK;
}
int sp_nas_list(sp_nas_client *client, const char *path, sp_nas_entry_callback callback, void *context) {
    return list_internal(client, path, NULL, callback, NULL, context);
}
int sp_nas_list_paths(sp_nas_client *client, const char *path, const char *encoded_path,
                     sp_nas_path_entry_callback callback, void *context) {
    return list_internal(client, path, encoded_path, NULL, callback, context);
}
sp_nas_file *sp_nas_open(sp_nas_client *client, const char *path, int64_t *size, int *status) {
    return sp_nas_open_path(client, path, NULL, size, status);
}
sp_nas_file *sp_nas_open_path(sp_nas_client *client, const char *path, const char *wire_path, int64_t *size, int *status) {
    return sp_nas_open_path_with_size(client, path, wire_path, -1, size, status);
}
sp_nas_file *sp_nas_open_path_with_size(sp_nas_client *client, const char *path, const char *wire_path,
                                      int64_t expected_size, int64_t *size, int *status) {
    if (status) *status = SP_NAS_INVALID;
    if (!client || !valid_path(path) || !size || expected_size < -1 || (wire_path && !valid_wire_path(wire_path))) return NULL;
    sp_nas_file *file = calloc(1, sizeof(*file));
    if (!file) { if (status) *status = SP_NAS_IO; return NULL; }
    file->client = client; file->size = -1;
    int error = SP_NAS_IO;
    if (client->protocol == SP_NAS_SMB) {
        if (!client->smb) { error = SP_NAS_CLOSED; goto failure; }
        while (*path == '/') path++;
        struct smb_result result = {0};
        if (smb2_open_async(client->smb, path, O_RDONLY, smb_result_cb, &result) < 0) goto failure;
        error = smb_wait(client, &result);
        if (error < 0) goto failure;
        file->smb = result.data;
        if (!file->smb) goto failure;
        struct smb2_stat_64 stat;
        result = (struct smb_result){0};
        if (smb2_fstat_async(client->smb, file->smb, &stat, smb_result_cb, &result) < 0) goto failure;
        error = smb_wait(client, &result);
        if (error < 0 || stat.smb2_size > INT64_MAX || stat.smb2_type != SMB2_TYPE_FILE) goto failure;
        file->size = (int64_t)stat.smb2_size;
    } else {
        file->path = strdup(path);
        file->wire_path = wire_path ? strdup(wire_path) : wire_path_from_display(client, path);
        if (!file->path || !file->wire_path) goto failure;
        uint8_t probe;
        error = ftp_transfer(client, path, file->wire_path, 0, 0, &probe, 1, &file->size);
        if (error >= 0 && file->size < 0 && expected_size >= error) file->size = expected_size;
        if (error < 0 || file->size < 0) goto failure;
    }
    *size = file->size;
    if (status) *status = SP_NAS_OK;
    return file;
failure:
    if (status) *status = error < 0 ? error : SP_NAS_IO;
    sp_nas_close(file); return NULL;
}

int sp_nas_read(sp_nas_file *file, int64_t offset, uint8_t *buffer, uint32_t count) {
    if (!file || !buffer || offset < 0 || count > MAX_READ) return SP_NAS_INVALID;
    if (offset >= file->size || count == 0) return 0;
    if ((uint64_t)count > (uint64_t)(file->size - offset)) count = (uint32_t)(file->size - offset);
    if (file->client->protocol == SP_NAS_SMB) {
        if (!file->client->smb) return SP_NAS_CLOSED;
        uint32_t maximum = smb2_get_max_read_size(file->client->smb);
        if (!maximum) maximum = 65536;
        if (count > maximum) count = maximum;
        struct smb_result result = {0};
        if (smb2_pread_async(file->client->smb, file->smb, buffer, count, (uint64_t)offset, smb_result_cb, &result) < 0) return SP_NAS_IO;
        return smb_wait(file->client, &result);
    }
    return ftp_read_file(file, offset, buffer, count);
}

void sp_nas_close(sp_nas_file *file) {
    if (!file) return;
    ftp_close_file_stream(file);
    if (file->smb && file->client->smb) {
        struct smb_result result = {0};
        if (smb2_close_async(file->client->smb, file->smb, smb_result_cb, &result) == 0) smb_wait(file->client, &result);
    }
    free(file->path);
    free(file->wire_path);
    free(file);
}
