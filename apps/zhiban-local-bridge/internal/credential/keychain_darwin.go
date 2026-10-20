//go:build darwin && cgo

package credential

/*
#cgo LDFLAGS: -framework CoreFoundation -framework Security
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	void *bytes;
	CFIndex length;
	OSStatus status;
} ZBKeychainLoadResult;

static CFStringRef zb_account_string(const uint8_t *bytes, size_t length) {
	return CFStringCreateWithBytes(
		kCFAllocatorDefault,
		bytes,
		(CFIndex)length,
		kCFStringEncodingUTF8,
		false
	);
}

// Community BYOK deliberately uses the login Keychain. Platform device
// credentials keep Data Protection Keychain; failures never switch stores.
static int zb_community_byok(const uint8_t *bytes, size_t length) {
 const char *codex="community-byok-codex_cli-v1";
 const char *claude="community-byok-claude_cli-v1";
 return (length==strlen(codex) && memcmp(bytes,codex,length)==0) ||
        (length==strlen(claude) && memcmp(bytes,claude,length)==0);
}

static CFMutableDictionaryRef zb_base_query(const uint8_t *account_bytes, size_t account_length) {
	CFStringRef account = zb_account_string(account_bytes, account_length);
	if (account == NULL) {
		return NULL;
	}
	CFMutableDictionaryRef query = CFDictionaryCreateMutable(
		kCFAllocatorDefault,
		0,
		&kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks
	);
	if (query == NULL) {
		CFRelease(account);
		return NULL;
	}
	CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(query, kSecAttrService, zb_community_byok(account_bytes,account_length) ? CFSTR("cn.zhiban.community.local-coding") : CFSTR("cn.zhiban.local-coding"));
	CFDictionarySetValue(query, kSecAttrAccount, account);
	if (!zb_community_byok(account_bytes,account_length)) {
 CFDictionarySetValue(query, kSecUseDataProtectionKeychain, kCFBooleanTrue);
 }
	CFDictionarySetValue(query, kSecAttrSynchronizable, kCFBooleanFalse);
	CFRelease(account);
	return query;
}

static OSStatus zb_keychain_save(
	const uint8_t *account_bytes,
	size_t account_length,
	const uint8_t *value_bytes,
	size_t value_length
) {
	CFDataRef data = CFDataCreate(kCFAllocatorDefault, value_bytes, (CFIndex)value_length);
	CFMutableDictionaryRef add_query = zb_base_query(account_bytes, account_length);
	if (data == NULL || add_query == NULL) {
		if (data != NULL) CFRelease(data);
		if (add_query != NULL) CFRelease(add_query);
		return errSecAllocate;
	}
	CFDictionarySetValue(add_query, kSecValueData, data);
	if (!zb_community_byok(account_bytes,account_length)) {
 CFDictionarySetValue(add_query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
 }
	OSStatus status = SecItemAdd(add_query, NULL);
	CFRelease(add_query);
	if (status == errSecDuplicateItem) {
		CFMutableDictionaryRef match_query = zb_base_query(account_bytes, account_length);
		CFMutableDictionaryRef updates = CFDictionaryCreateMutable(
			kCFAllocatorDefault,
			0,
			&kCFTypeDictionaryKeyCallBacks,
			&kCFTypeDictionaryValueCallBacks
		);
		if (match_query == NULL || updates == NULL) {
			if (match_query != NULL) CFRelease(match_query);
			if (updates != NULL) CFRelease(updates);
			CFRelease(data);
			return errSecAllocate;
		}
		CFDictionarySetValue(updates, kSecValueData, data);
		if (!zb_community_byok(account_bytes,account_length)) {
 CFDictionarySetValue(updates, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
 }
		status = SecItemUpdate(match_query, updates);
		CFRelease(match_query);
		CFRelease(updates);
	}
	CFRelease(data);
	return status;
}

static ZBKeychainLoadResult zb_keychain_load(const uint8_t *account_bytes, size_t account_length) {
	ZBKeychainLoadResult output = {NULL, 0, errSecInternalComponent};
	CFMutableDictionaryRef query = zb_base_query(account_bytes, account_length);
	if (query == NULL) {
		output.status = errSecAllocate;
		return output;
	}
	CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
	CFTypeRef result = NULL;
	output.status = SecItemCopyMatching(query, &result);
	CFRelease(query);
	if (output.status != errSecSuccess) {
		return output;
	}
	if (result == NULL || CFGetTypeID(result) != CFDataGetTypeID()) {
		if (result != NULL) CFRelease(result);
		output.status = errSecDecode;
		return output;
	}
	CFDataRef data = (CFDataRef)result;
	output.length = CFDataGetLength(data);
	if (output.length <= 0) {
		CFRelease(data);
		output.status = errSecDecode;
		return output;
	}
	output.bytes = malloc((size_t)output.length);
	if (output.bytes == NULL) {
		CFRelease(data);
		output.status = errSecAllocate;
		return output;
	}
	memcpy(output.bytes, CFDataGetBytePtr(data), (size_t)output.length);
	CFRelease(data);
	return output;
}

static OSStatus zb_keychain_delete(const uint8_t *account_bytes, size_t account_length) {
	CFMutableDictionaryRef query = zb_base_query(account_bytes, account_length);
	if (query == NULL) {
		return errSecAllocate;
	}
	OSStatus status = SecItemDelete(query);
	CFRelease(query);
	return status;
}
*/
import "C"

import (
	"context"
	"fmt"
	"unsafe"
)

const (
	keychainStatusSuccess      int32 = 0
	keychainStatusItemNotFound int32 = -25300
)

type macOSKeychainBackend struct{}

func NewMacOSKeychainStore() Store {
	return newKeychainStore(macOSKeychainBackend{})
}

func (macOSKeychainBackend) Load(ctx context.Context, account string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	accountBytes := []byte(account)
	if len(accountBytes) == 0 {
		return nil, ErrInvalidData
	}
	result := C.zb_keychain_load((*C.uint8_t)(unsafe.Pointer(&accountBytes[0])), C.size_t(len(accountBytes)))
	if err := keychainStatusError(int32(result.status)); err != nil {
		return nil, err
	}
	if result.bytes == nil || result.length <= 0 || uint64(result.length) > uint64(maxKeychainItemBytes) {
		if result.bytes != nil {
			if result.length > 0 {
				C.memset(result.bytes, 0, C.size_t(result.length))
			}
			C.free(result.bytes)
		}
		return nil, ErrInvalidData
	}
	value := C.GoBytes(result.bytes, C.int(result.length))
	C.memset(result.bytes, 0, C.size_t(result.length))
	C.free(result.bytes)
	return value, nil
}

func (macOSKeychainBackend) Save(ctx context.Context, account string, value []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if account == "" || len(value) == 0 || len(value) > maxKeychainItemBytes {
		return ErrInvalidData
	}
	accountBytes := []byte(account)
	valueCopy := C.CBytes(value)
	defer func() {
		C.memset(valueCopy, 0, C.size_t(len(value)))
		C.free(valueCopy)
	}()
	status := C.zb_keychain_save(
		(*C.uint8_t)(unsafe.Pointer(&accountBytes[0])),
		C.size_t(len(accountBytes)),
		(*C.uint8_t)(valueCopy),
		C.size_t(len(value)),
	)
	return keychainStatusError(int32(status))
}

func (macOSKeychainBackend) Delete(ctx context.Context, account string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	accountBytes := []byte(account)
	if len(accountBytes) == 0 {
		return ErrInvalidData
	}
	status := C.zb_keychain_delete((*C.uint8_t)(unsafe.Pointer(&accountBytes[0])), C.size_t(len(accountBytes)))
	return keychainStatusError(int32(status))
}

func keychainStatusError(status int32) error {
	switch status {
	case keychainStatusSuccess:
		return nil
	case keychainStatusItemNotFound:
		return ErrNotFound
	default:
		return fmt.Errorf("%w: status %d", ErrKeychainUnavailable, status)
	}
}
