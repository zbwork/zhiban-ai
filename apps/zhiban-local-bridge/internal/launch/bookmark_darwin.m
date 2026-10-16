#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

int zb_resolve_bookmark(const void *bytes, size_t length, char **path, int *stale) {
  if (bytes == NULL || length == 0 || path == NULL || stale == NULL) {
    return 1;
  }
  @autoreleasepool {
    NSData *data = [NSData dataWithBytes:bytes length:length];
    BOOL bookmarkIsStale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:data
                                          options:0
                                    relativeToURL:nil
                              bookmarkDataIsStale:&bookmarkIsStale
                                            error:&error];
    if (url == nil || error != nil || !url.isFileURL || url.path == nil) {
      return 2;
    }
    const char *fileSystemPath = url.fileSystemRepresentation;
    if (fileSystemPath == NULL) {
      return 2;
    }
    char *copy = strdup(fileSystemPath);
    if (copy == NULL) {
      return 3;
    }
    *path = copy;
    *stale = bookmarkIsStale ? 1 : 0;
    return 0;
  }
}

int zb_create_bookmark(const char *path, void **bytes, size_t *length) {
  if (path == NULL || bytes == NULL || length == NULL) {
    return 1;
  }
  @autoreleasepool {
    NSString *value = [[NSFileManager defaultManager]
      stringWithFileSystemRepresentation:path
                                  length:strlen(path)];
    if (value == nil) {
      return 2;
    }
    NSURL *url = [NSURL fileURLWithPath:value isDirectory:YES];
    NSError *error = nil;
    NSData *data = [url bookmarkDataWithOptions:0
                 includingResourceValuesForKeys:nil
                                  relativeToURL:nil
                                          error:&error];
    if (data == nil || error != nil || data.length == 0) {
      return 2;
    }
    void *copy = malloc(data.length);
    if (copy == NULL) {
      return 3;
    }
    memcpy(copy, data.bytes, data.length);
    *bytes = copy;
    *length = data.length;
    return 0;
  }
}

void zb_release_buffer(void *buffer) {
  free(buffer);
}
