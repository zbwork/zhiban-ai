// SigV4 (AWS Signature Version 4) presign / sign 实现 (pure stdlib).
//
// 用途:
//   - 给 PUT / GET / DELETE 生成短期签名 URL (presign) — 客户端 / 服务端可直接对 OSS / S3 / MinIO 发请求
//   - AliYun OSS 已支持 S3 兼容 API; 此实现同时覆盖 AWS S3 / MinIO / AliYun OSS S3-compatible endpoint
//
// 参考:
//   - https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
//   - https://help.aliyun.com/zh/oss/developer-reference/use-the-amazon-s3-sdks-for-go-to-access-oss
//
// 关键细节:
//   - 算法: AWS4-HMAC-SHA256
//   - service = "s3" (即使后端是 AliYun OSS / MinIO)
//   - presign 时使用 UNSIGNED-PAYLOAD; 服务端校验只看签名而非 body 哈希
package oss

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

const (
	algorithm     = "AWS4-HMAC-SHA256"
	service       = "s3"
	requestSuffix = "aws4_request"
	// emptyHashHex 是 SHA256("") 的 hex 编码 — 当 payload 为空时 (服务器端 DELETE 用)
	emptyHashHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	// unsignedPayload 用于 presign — 客户端实际传输的字节不参与签名
	unsignedPayload = "UNSIGNED-PAYLOAD"
)

// presignerInput 是 presign 一个 URL 所需的最小信息.
type presignerInput struct {
	Method          string        // PUT / GET / DELETE / POST / HEAD
	Endpoint        string        // 不带 path 的 host: https://oss-cn-hangzhou.aliyuncs.com
	Bucket          string        // bucket 名 (path-style 默认)
	Key             string        // object key (不带前导 /)
	Region          string        // 签名 region
	AccessKeyID     string        // AK
	SecretAccessKey string        // SK
	Expires         time.Duration // 过期时长 (秒精度)
	Now             time.Time     // 签名时间 (UTC)
	// ContentType 仅用于 PUT 时 SignedHeaders 包含 content-type;
	// 客户端 PUT 时必须带相同 Content-Type 头, 否则 OSS / S3 拒.
	ContentType string
	// ResponseContentDisposition GET 时附加 query 用于强制 inline / attachment + filename.
	ResponseContentDisposition string
	// ResponseContentType GET 时附加 query 用于强制响应 Content-Type
	// (对象元数据类型错存时浏览器预览需要真实 mime)。
	ResponseContentType string
	// ForcePathStyle = true 强制 https://endpoint/bucket/key (MinIO 默认);
	// = false 走 virtual-hosted https://bucket.endpoint/key (AliYun OSS / S3 默认).
	ForcePathStyle bool
	// ExtraQuery F06 Phase 2.M: 额外参与 canonical query 的查询参数 (uploads, uploadId, partNumber 等).
	// 这些 key 与 X-Amz-* / response-* 一同排序后参与签名; 不在此 map 的参数追加在 URL 上 OSS 会拒.
	ExtraQuery url.Values
}

// presignResult 是 presign 输出.
type presignResult struct {
	URL       string
	ExpiresAt time.Time
	// Headers 客户端发请求时**必须**带的 header (即被签名的 SignedHeaders).
	Headers map[string]string
}

// presign 生成 SigV4 query 模式签名 URL.
func presign(in presignerInput) (*presignResult, error) {
	if in.Endpoint == "" {
		return nil, fmt.Errorf("oss/sigv4: endpoint required")
	}
	if in.Bucket == "" {
		return nil, fmt.Errorf("oss/sigv4: bucket required")
	}
	if in.Key == "" {
		return nil, fmt.Errorf("oss/sigv4: key required")
	}
	if in.AccessKeyID == "" || in.SecretAccessKey == "" {
		return nil, fmt.Errorf("oss/sigv4: AK/SK required")
	}
	if in.Method == "" {
		in.Method = "GET"
	}
	if in.Region == "" {
		in.Region = "us-east-1"
	}
	if in.Expires <= 0 {
		in.Expires = 5 * time.Minute
	}
	now := in.Now.UTC()
	if now.IsZero() {
		now = time.Now().UTC()
	}
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")
	scope := fmt.Sprintf("%s/%s/%s/%s", dateStamp, in.Region, service, requestSuffix)

	hostURL, hostHeader, pathPrefix, err := buildHost(in.Endpoint, in.Bucket, in.ForcePathStyle)
	if err != nil {
		return nil, err
	}

	// SignedHeaders: host 始终参与; PUT 时附 content-type (客户端必须带相同 header).
	signedHeaderKeys := []string{"host"}
	headers := map[string]string{"host": hostHeader}
	if in.Method == "PUT" && in.ContentType != "" {
		signedHeaderKeys = append(signedHeaderKeys, "content-type")
		headers["content-type"] = in.ContentType
	}
	sort.Strings(signedHeaderKeys)
	signedHeadersStr := strings.Join(signedHeaderKeys, ";")
	canonicalHeaders := ""
	for _, k := range signedHeaderKeys {
		canonicalHeaders += k + ":" + strings.TrimSpace(headers[k]) + "\n"
	}

	credential := fmt.Sprintf("%s/%s", in.AccessKeyID, scope)

	// canonical query (按 key 排序, 全部 RFC3986 编码).
	q := url.Values{}
	q.Set("X-Amz-Algorithm", algorithm)
	q.Set("X-Amz-Credential", credential)
	q.Set("X-Amz-Date", amzDate)
	q.Set("X-Amz-Expires", fmt.Sprintf("%d", int64(in.Expires.Seconds())))
	q.Set("X-Amz-SignedHeaders", signedHeadersStr)
	if in.ResponseContentDisposition != "" {
		q.Set("response-content-disposition", in.ResponseContentDisposition)
	}
	if in.ResponseContentType != "" {
		q.Set("response-content-type", in.ResponseContentType)
	}
	// F06 Phase 2.M: 多分片需要把 uploads / uploadId / partNumber 当 canonical query 一起签名.
	for k, vs := range in.ExtraQuery {
		for _, v := range vs {
			q.Add(k, v)
		}
	}
	canonicalQuery := canonicalEncodeValues(q)

	canonicalURI := pathPrefix + uriEncodeKey(in.Key)
	canonicalRequest := strings.Join([]string{
		in.Method,
		canonicalURI,
		canonicalQuery,
		canonicalHeaders,
		signedHeadersStr,
		unsignedPayload,
	}, "\n")
	hashedCanonical := sha256Hex([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{algorithm, amzDate, scope, hashedCanonical}, "\n")

	signingKey := deriveSigningKey(in.SecretAccessKey, dateStamp, in.Region, service)
	signature := hex.EncodeToString(hmacSha256(signingKey, []byte(stringToSign)))
	q.Set("X-Amz-Signature", signature)

	full := hostURL + canonicalURI + "?" + canonicalEncodeValues(q)

	outHeaders := map[string]string{}
	if in.Method == "PUT" && in.ContentType != "" {
		outHeaders["Content-Type"] = in.ContentType
	}
	return &presignResult{
		URL:       full,
		ExpiresAt: now.Add(in.Expires),
		Headers:   outHeaders,
	}, nil
}

// buildHost 根据 endpoint + bucket + ForcePathStyle 推导 base URL + host header + path prefix.
//
// path-style:    https://endpoint        + Host: endpoint           + path prefix /bucket
// virtual-host:  https://bucket.endpoint + Host: bucket.endpoint    + path prefix ""
func buildHost(endpoint, bucket string, forcePath bool) (baseURL, host, pathPrefix string, err error) {
	u, err := url.Parse(endpoint)
	if err != nil {
		return "", "", "", fmt.Errorf("oss/sigv4: invalid endpoint %q: %w", endpoint, err)
	}
	if u.Scheme == "" {
		u, err = url.Parse("https://" + endpoint)
		if err != nil {
			return "", "", "", fmt.Errorf("oss/sigv4: invalid endpoint %q: %w", endpoint, err)
		}
	}
	if u.Host == "" {
		return "", "", "", fmt.Errorf("oss/sigv4: endpoint missing host: %q", endpoint)
	}
	scheme := u.Scheme
	if scheme == "" {
		scheme = "https"
	}
	if forcePath {
		baseURL = scheme + "://" + u.Host
		host = u.Host
		pathPrefix = "/" + bucket + "/"
	} else {
		baseURL = scheme + "://" + bucket + "." + u.Host
		host = bucket + "." + u.Host
		pathPrefix = "/"
	}
	return baseURL, host, pathPrefix, nil
}

// deriveSigningKey 派生 SigV4 签名密钥.
func deriveSigningKey(secret, dateStamp, region, svc string) []byte {
	kDate := hmacSha256([]byte("AWS4"+secret), []byte(dateStamp))
	kRegion := hmacSha256(kDate, []byte(region))
	kService := hmacSha256(kRegion, []byte(svc))
	return hmacSha256(kService, []byte(requestSuffix))
}

func hmacSha256(key, msg []byte) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write(msg)
	return mac.Sum(nil)
}

func sha256Hex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// uriEncodeKey 按 SigV4 规则 encode object key:
//   - 路径分隔符 / 不编码
//   - 其它字符按 RFC3986 unreserved 保留 (字母/数字/-/./_/~), 其余 %HH
func uriEncodeKey(key string) string {
	var b strings.Builder
	b.Grow(len(key))
	for i := 0; i < len(key); i++ {
		c := key[i]
		switch {
		case (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'),
			c == '-' || c == '.' || c == '_' || c == '~', c == '/':
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// canonicalEncodeValues 把 url.Values 序列化成 RFC3986 (key 排序; 每个 value RFC3986 编码).
func canonicalEncodeValues(v url.Values) string {
	if len(v) == 0 {
		return ""
	}
	keys := make([]string, 0, len(v))
	for k := range v {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(v))
	for _, k := range keys {
		for _, val := range v[k] {
			parts = append(parts, rfc3986Escape(k)+"="+rfc3986Escape(val))
		}
	}
	return strings.Join(parts, "&")
}

// signHeaderAuthRequest F06 Phase 2.M: SigV4 *header-mode* 签名 (Authorization 头), 区别于 presign 的 query 模式.
//
// 用途:
//   - CompleteMultipart: POST <key>?uploadId=X + XML body → body 哈希必须签名 (不能 UNSIGNED-PAYLOAD)
//   - AbortMultipart:    DELETE <key>?uploadId=X (空 body → emptyHash)
//   - InitMultipart:     POST <key>?uploads
//   - Copy:              PUT <dstKey> + x-amz-copy-source header (custom header 必须签名)
//
// 调用方:
//  1. http.NewRequest(method, fullURL, bodyReader)  // URL 必须含 query
//  2. 若有 body, 把 sha256 hex 准备好 (空 body 用 emptyHashHex; XML body 自己算)
//  3. 把 custom headers (e.g. x-amz-copy-source) Set 到 req.Header 中
//  4. signHeaderAuthRequest(req, secret, ak, region, payloadHash, now)
//  5. http.Client.Do(req)
//
// 实现细节:
//   - SignedHeaders 至少含 host + x-amz-date + x-amz-content-sha256;
//     若 req.Header 中有 content-type / x-amz-* 自定义头, 一并加入并排序签名
//   - canonical query 直接取 req.URL.Query() 排序 RFC3986
//   - canonical request 末尾用 payloadHash (不是 UNSIGNED-PAYLOAD)
//   - 写回 Authorization: AWS4-HMAC-SHA256 Credential=... SignedHeaders=... Signature=...
func signHeaderAuthRequest(req *http.Request, secretKey, accessKey, region, payloadHash string, now time.Time) {
	now = now.UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")
	scope := fmt.Sprintf("%s/%s/%s/%s", dateStamp, region, service, requestSuffix)

	// 强制头: host + x-amz-date + x-amz-content-sha256.
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)

	// 收集签名 header 列表 (lowercase key 排序).
	signedKeys := []string{"host", "x-amz-content-sha256", "x-amz-date"}
	headerVals := map[string]string{
		"host":                 req.URL.Host,
		"x-amz-content-sha256": payloadHash,
		"x-amz-date":           amzDate,
	}
	// 收 content-type + x-amz-* 自定义头 (req.Header 已 Set).
	for k, vs := range req.Header {
		lk := strings.ToLower(k)
		if lk == "x-amz-date" || lk == "x-amz-content-sha256" || lk == "authorization" {
			continue
		}
		if lk == "content-type" || strings.HasPrefix(lk, "x-amz-") {
			signedKeys = append(signedKeys, lk)
			headerVals[lk] = strings.TrimSpace(vs[0])
		}
	}
	sort.Strings(signedKeys)
	// 去重 (host/x-amz-date/x-amz-content-sha256 可能被上面循环加重).
	signedKeys = dedupSorted(signedKeys)
	signedHeadersStr := strings.Join(signedKeys, ";")

	canonicalHeaders := ""
	for _, k := range signedKeys {
		canonicalHeaders += k + ":" + headerVals[k] + "\n"
	}

	canonicalQuery := canonicalEncodeValues(req.URL.Query())
	canonicalURI := uriEncodePath(req.URL.Path)

	canonicalRequest := strings.Join([]string{
		req.Method,
		canonicalURI,
		canonicalQuery,
		canonicalHeaders,
		signedHeadersStr,
		payloadHash,
	}, "\n")
	hashedCanonical := sha256Hex([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{algorithm, amzDate, scope, hashedCanonical}, "\n")
	signingKey := deriveSigningKey(secretKey, dateStamp, region, service)
	signature := hex.EncodeToString(hmacSha256(signingKey, []byte(stringToSign)))
	credential := fmt.Sprintf("%s/%s", accessKey, scope)
	auth := fmt.Sprintf("%s Credential=%s, SignedHeaders=%s, Signature=%s",
		algorithm, credential, signedHeadersStr, signature)
	req.Header.Set("Authorization", auth)
}

// dedupSorted 去掉已排序 slice 中相邻重复.
func dedupSorted(s []string) []string {
	if len(s) <= 1 {
		return s
	}
	out := s[:1]
	for i := 1; i < len(s); i++ {
		if s[i] != s[i-1] {
			out = append(out, s[i])
		}
	}
	return out
}

// uriEncodePath 对 req.URL.Path 做 canonical encode (含分段保留 /).
// 与 uriEncodeKey 相同行为, 但接受任意 path (含前导 /).
func uriEncodePath(p string) string {
	if p == "" {
		return "/"
	}
	return uriEncodeKey(p)
}

func rfc3986Escape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'),
			c == '-' || c == '.' || c == '_' || c == '~':
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
