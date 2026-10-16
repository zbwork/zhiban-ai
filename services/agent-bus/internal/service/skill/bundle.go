package skill

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"sort"
	"strings"
	"time"

	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const (
	SkillBundleFormatVersion = 1
	MaxSkillBundleSkills     = 20
	MaxSkillBundleBytes      = 200 * 1024 * 1024
	maxSkillBundleFiles      = 256
	maxSkillBundleManifest   = 2 * 1024 * 1024
)

// bundleCodePattern accepts stable keys that already exist in the platform
// catalog. Admin create/update keeps using the stricter underscore-only
// codePattern; bundle import must remain symmetric with export.
var bundleCodePattern = regexp.MustCompile(`^[a-z][a-z0-9_-]{2,63}$`)

type SkillBundleManifest struct {
	FormatVersion int                `json:"format_version"`
	ExportedAt    time.Time          `json:"exported_at"`
	Skills        []SkillBundleEntry `json:"skills"`
}

type SkillBundleEntry struct {
	Code     string               `json:"code"`
	Metadata SkillBundleMetadata  `json:"metadata"`
	Category *SkillBundleCategory `json:"category,omitempty"`
	Labels   []SkillBundleLabel   `json:"labels"`
	Assets   []SkillBundleAsset   `json:"assets,omitempty"`
	Version  SkillBundleVersion   `json:"version"`
	Billing  SkillBundleBilling   `json:"billing"`
}

type SkillBundleMetadata struct {
	Name               string          `json:"name"`
	Description        string          `json:"description"`
	UsageExample       string          `json:"usage_example"`
	UsageExampleImages json.RawMessage `json:"usage_example_images"`
	IconURL            string          `json:"icon_url"`
	Placeholder        string          `json:"placeholder"`
	SubmitLabel        string          `json:"submit_label"`
	Kind               string          `json:"kind"`
	BuiltinKey         *string         `json:"builtin_key,omitempty"`
	ExecutionMode      string          `json:"execution_mode"`
	Source             string          `json:"source"`
	Visibility         string          `json:"visibility"`
	HostingModes       []string        `json:"hosting_modes"`
	DefaultAttached    bool            `json:"default_attached"`
	DefaultPinned      bool            `json:"default_pinned"`
	SortOrder          int             `json:"sort_order"`
	MarketingVisible   bool            `json:"marketing_visible"`
}

type SkillBundleCategory struct {
	Code         string `json:"code"`
	Name         string `json:"name"`
	CategoryKind string `json:"category_kind"`
	Description  string `json:"description"`
	SortOrder    int    `json:"sort_order"`
}

type SkillBundleLabel struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
}

type SkillBundleAsset struct {
	Kind        string `json:"kind"` // icon | usage_example
	Index       int    `json:"index,omitempty"`
	Path        string `json:"path"`
	SHA256      string `json:"sha256"`
	ContentType string `json:"content_type"`
	FileName    string `json:"file_name,omitempty"`
}

type SkillBundleVersion struct {
	Version                  string          `json:"version"`
	Changelog                string          `json:"changelog"`
	PackagePath              string          `json:"package_path,omitempty"`
	PackageSHA256            string          `json:"package_sha256,omitempty"`
	InputChipsSchemaSnapshot json.RawMessage `json:"input_chips_schema_snapshot"`
	AgentCompatSnapshot      json.RawMessage `json:"agent_compat_snapshot"`
	ContentSHA256            string          `json:"content_sha256"`
}

type SkillBundleBilling struct {
	BillingType           string                 `json:"billing_type"`
	PricingMode           string                 `json:"pricing_mode"`
	DefaultCreditsPerCall *int64                 `json:"default_credits_per_call,omitempty"`
	Operations            []SkillBundleOperation `json:"operations"`
}

type SkillBundleOperation struct {
	OperationCode  string          `json:"operation_code"`
	OperationName  string          `json:"operation_name"`
	Description    string          `json:"description"`
	InputSchema    json.RawMessage `json:"input_schema"`
	OutputSchema   json.RawMessage `json:"output_schema"`
	SortOrder      int             `json:"sort_order"`
	CreditsPerCall *int64          `json:"credits_per_call,omitempty"`
}

type ExportSkillBundleInput struct {
	SkillUUIDs []string
	OperatorID int64
}

type ExportSkillBundleOutput struct {
	Body     []byte
	Filename string
	SHA256   string
}

type ImportSkillBundleInput struct {
	Body       io.Reader
	OperatorID int64
}

type ImportSkillBundleItem struct {
	Code    string `json:"code"`
	Version string `json:"version"`
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type ImportSkillBundleOutput struct {
	BundleSHA256 string                  `json:"bundle_sha256"`
	Created      int                     `json:"created"`
	Updated      int                     `json:"updated"`
	Skipped      int                     `json:"skipped"`
	Conflict     int                     `json:"conflict"`
	Failed       int                     `json:"failed"`
	Items        []ImportSkillBundleItem `json:"items"`
}

func (s *Service) ExportSkillBundle(ctx context.Context, in ExportSkillBundleInput) (*ExportSkillBundleOutput, error) {
	uuids, err := normalizeBundleUUIDs(in.SkillUUIDs)
	if err != nil {
		return nil, err
	}
	manifest := SkillBundleManifest{FormatVersion: SkillBundleFormatVersion, ExportedAt: time.Now().UTC()}
	packages := make(map[string][]byte, len(uuids))
	for _, uuid := range uuids {
		sk, err := s.repo.GetSkillByUUID(ctx, uuid, false)
		if err != nil {
			return nil, err
		}
		if sk.ScopeKind != domskill.ScopePlatform {
			return nil, apperr.ErrInvalidParams.Withf("skill.bundle_export_platform_only: %s", sk.Code)
		}
		ver, err := s.repo.GetLatestPublishedVersion(ctx, sk.ID)
		if err != nil {
			return nil, err
		}
		if ver == nil || ver.Status != domskill.VersionStatusPublished {
			return nil, apperr.ErrInvalidParams.Withf("skill.bundle_export_requires_published_version: %s", sk.Code)
		}
		entry, err := s.exportBundleEntry(ctx, sk, ver)
		if err != nil {
			return nil, err
		}
		assetFiles, err := s.exportBundleAssets(ctx, sk, &entry)
		if err != nil {
			return nil, err
		}
		for name, body := range assetFiles {
			packages[name] = body
		}
		if sk.Kind == domskill.KindAgent {
			if s.packages == nil {
				return nil, apperr.ErrInternal.Withf("skill package store not configured")
			}
			body, err := s.packages.ReadObject(ctx, ver.PackageURL, domskill.PackageMaxBytes, "skill")
			if err != nil {
				return nil, fmt.Errorf("export package %s: %w", sk.Code, err)
			}
			digest := sha256Hex(body)
			if !strings.EqualFold(digest, ver.PackageSHA256) {
				return nil, apperr.ErrConflict.Withf("skill.bundle_package_checksum_mismatch: %s", sk.Code)
			}
			entry.Version.PackagePath = fmt.Sprintf("skills/%s/%s.zip", sk.Code, ver.Version)
			entry.Version.PackageSHA256 = digest
			entry.Version.ContentSHA256 = digest
			packages[entry.Version.PackagePath] = body
		}
		manifest.Skills = append(manifest.Skills, entry)
	}

	manifestJSON, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	zw := zip.NewWriter(&out)
	if err := writeBundleZipFile(zw, "manifest.json", manifestJSON); err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(packages))
	for p := range packages {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		if err := writeBundleZipFile(zw, p, packages[p]); err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	if out.Len() > MaxSkillBundleBytes {
		return nil, apperr.ErrInvalidParams.Withf("skill.bundle_too_large: max %d bytes", MaxSkillBundleBytes)
	}
	digest := sha256Hex(out.Bytes())
	s.auditBundle(ctx, "export", in.OperatorID, digest, manifest.Skills, nil)
	return &ExportSkillBundleOutput{
		Body: out.Bytes(), Filename: fmt.Sprintf("skills-%s.skillbundle.zip", time.Now().UTC().Format("20060102-150405")), SHA256: digest,
	}, nil
}

func (s *Service) exportBundleEntry(ctx context.Context, sk *domskill.Skill, ver *domskill.SkillVersion) (SkillBundleEntry, error) {
	entry := SkillBundleEntry{
		Code: sk.Code,
		Metadata: SkillBundleMetadata{
			Name: sk.Name, Description: sk.Description, UsageExample: sk.UsageExample,
			UsageExampleImages: rawOrDefault(sk.UsageExampleImages, emptyJSONArr), IconURL: sk.IconURL,
			Placeholder: sk.Placeholder, SubmitLabel: sk.SubmitLabel, Kind: sk.Kind, BuiltinKey: sk.BuiltinKey,
			ExecutionMode: sk.ExecutionMode, Source: sk.Source, Visibility: sk.Visibility,
			HostingModes: append([]string(nil), sk.HostingModes...), DefaultAttached: sk.DefaultAttached,
			DefaultPinned: sk.DefaultPinned, SortOrder: sk.SortOrder, MarketingVisible: sk.MarketingVisible,
		},
		Labels: []SkillBundleLabel{},
		Version: SkillBundleVersion{
			Version: ver.Version, Changelog: ver.Changelog,
			InputChipsSchemaSnapshot: rawOrDefault(ver.InputChipsSchemaSnapshot, emptyJSONArr),
			AgentCompatSnapshot:      rawOrDefault(ver.AgentCompatSnapshot, emptyJSONObj),
		},
		Billing: SkillBundleBilling{BillingType: sk.BillingType, PricingMode: sk.PricingMode, DefaultCreditsPerCall: sk.DefaultCreditsPerCall, Operations: []SkillBundleOperation{}},
	}
	if entry.Billing.BillingType == "" {
		entry.Billing.BillingType = domskill.BillingTypeFree
	}
	if entry.Billing.PricingMode == "" {
		entry.Billing.PricingMode = domskill.PricingModePerSkill
	}
	if sk.CategoryID != nil {
		cats, _, err := s.repo.ListCategories(ctx, domskill.DictListFilter{Limit: 1000})
		if err != nil {
			return entry, err
		}
		for _, c := range cats {
			if c.ID == *sk.CategoryID {
				entry.Category = &SkillBundleCategory{Code: c.Code, Name: c.Name, CategoryKind: c.CategoryKind, Description: c.Description, SortOrder: c.SortOrder}
				break
			}
		}
	}
	labels, err := s.repo.ListSkillLabels(ctx, sk.ID)
	if err != nil {
		return entry, err
	}
	for _, l := range labels {
		entry.Labels = append(entry.Labels, SkillBundleLabel{Code: l.Code, Name: l.Name, Description: l.Description, SortOrder: l.SortOrder})
	}
	if sk.Kind == domskill.KindBuiltin {
		entry.Version.ContentSHA256 = builtinVersionDigest(entry.Version)
	}
	if s.billing != nil {
		ops, _, err := s.billing.ListSkillOperations(ctx, sk.ID, dombilling.SkillOperationFilter{Status: dombilling.OperationStatusActive, Limit: 500})
		if err != nil {
			return entry, err
		}
		prices, err := s.billing.ListSkillOperationPrices(ctx, sk.ID)
		if err != nil {
			return entry, err
		}
		priceByCode := make(map[string]*int64, len(prices))
		for _, p := range prices {
			if p.CreditsPerCall != nil {
				v := *p.CreditsPerCall
				priceByCode[p.OperationCode] = &v
			}
		}
		for _, op := range ops {
			entry.Billing.Operations = append(entry.Billing.Operations, SkillBundleOperation{
				OperationCode: op.OperationCode, OperationName: op.OperationName, Description: op.Description,
				InputSchema: rawOrDefault(op.InputSchema, emptyJSONObj), OutputSchema: rawOrDefault(op.OutputSchema, emptyJSONObj),
				SortOrder: op.SortOrder, CreditsPerCall: priceByCode[op.OperationCode],
			})
		}
	}
	return entry, nil
}

func (s *Service) exportBundleAssets(ctx context.Context, sk *domskill.Skill, entry *SkillBundleEntry) (map[string][]byte, error) {
	out := map[string][]byte{}
	if s.packages == nil && (strings.HasPrefix(sk.IconURL, "oss://skill-icons/") || bytes.Contains(sk.UsageExampleImages, []byte("oss://skill-example-images/"))) {
		return nil, errors.New("skill image store not configured")
	}
	if strings.HasPrefix(sk.IconURL, "oss://skill-icons/") {
		contentType, ext := bundleImageType(sk.IconURL)
		if contentType == "" {
			return nil, fmt.Errorf("export icon %s: unsupported extension", sk.Code)
		}
		body, err := s.packages.ReadObject(ctx, sk.IconURL, 1024*1024, "skill-icons")
		if err != nil {
			return nil, fmt.Errorf("export icon %s: %w", sk.Code, err)
		}
		name := fmt.Sprintf("assets/%s/icon%s", sk.Code, ext)
		entry.Assets = append(entry.Assets, SkillBundleAsset{Kind: "icon", Path: name, SHA256: sha256Hex(body), ContentType: contentType})
		out[name] = body
	}
	type usageImage struct {
		StorageURI string `json:"storage_uri"`
		URL        string `json:"url"`
		FileName   string `json:"file_name"`
	}
	var images []usageImage
	_ = json.Unmarshal(sk.UsageExampleImages, &images)
	for i, image := range images {
		uri := image.StorageURI
		if uri == "" {
			uri = image.URL
		}
		if !strings.HasPrefix(uri, "oss://skill-example-images/") {
			continue
		}
		contentType, ext := bundleImageType(uri)
		if contentType == "" {
			return nil, fmt.Errorf("export example image %s[%d]: unsupported extension", sk.Code, i)
		}
		body, err := s.packages.ReadObject(ctx, uri, 5*1024*1024, "skill-example-images")
		if err != nil {
			return nil, fmt.Errorf("export example image %s[%d]: %w", sk.Code, i, err)
		}
		name := fmt.Sprintf("assets/%s/examples/%d%s", sk.Code, i, ext)
		entry.Assets = append(entry.Assets, SkillBundleAsset{Kind: "usage_example", Index: i, Path: name, SHA256: sha256Hex(body), ContentType: contentType, FileName: image.FileName})
		out[name] = body
	}
	return out, nil
}

func (s *Service) ImportSkillBundle(ctx context.Context, in ImportSkillBundleInput) (*ImportSkillBundleOutput, error) {
	if in.Body == nil {
		return nil, apperr.ErrInvalidParams.Withf("skill.bundle_file_required")
	}
	body, err := io.ReadAll(io.LimitReader(in.Body, MaxSkillBundleBytes+1))
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("skill.bundle_read_failed")
	}
	if len(body) == 0 || len(body) > MaxSkillBundleBytes {
		return nil, apperr.ErrInvalidParams.Withf("skill.bundle_too_large: max %d bytes", MaxSkillBundleBytes)
	}
	manifest, files, err := parseAndValidateSkillBundle(body)
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("skill.bundle_invalid: %v", err)
	}
	digest := sha256Hex(body)
	out := &ImportSkillBundleOutput{BundleSHA256: digest, Items: make([]ImportSkillBundleItem, 0, len(manifest.Skills))}
	for _, entry := range manifest.Skills {
		item := s.importBundleEntry(ctx, entry, files, in.OperatorID)
		out.Items = append(out.Items, item)
		switch item.Status {
		case "created":
			out.Created++
		case "updated":
			out.Updated++
		case "skipped":
			out.Skipped++
		case "conflict":
			out.Conflict++
		default:
			out.Failed++
		}
	}
	s.auditBundle(ctx, "import", in.OperatorID, digest, manifest.Skills, out.Items)
	return out, nil
}

func (s *Service) importBundleEntry(ctx context.Context, entry SkillBundleEntry, files map[string][]byte, operatorID int64) ImportSkillBundleItem {
	item := ImportSkillBundleItem{Code: entry.Code, Version: entry.Version.Version, Status: "failed"}
	existing, err := s.findPlatformSkillByCode(ctx, entry.Code)
	if err != nil {
		item.Message = safeBundleError(err)
		return item
	}
	if existing != nil && (existing.Kind != entry.Metadata.Kind || !sameOptionalString(existing.BuiltinKey, entry.Metadata.BuiltinKey)) {
		item.Status, item.Message = "conflict", "目标环境已存在同 Code 但类型或 builtin_key 不同"
		return item
	}
	var resumableAgentVersion *domskill.SkillVersion
	if existing != nil {
		versions, err := s.repo.ListVersions(ctx, existing.ID)
		if err != nil {
			item.Message = safeBundleError(err)
			return item
		}
		for _, v := range versions {
			if v.Version != entry.Version.Version {
				continue
			}
			if existing.Kind == domskill.KindAgent && v.Status == domskill.VersionStatusDraft && v.PackageURL == "pending://upload" && v.PackageSHA256 == "" {
				copy := v
				resumableAgentVersion = &copy
				break
			}
			targetDigest := strings.ToLower(v.PackageSHA256)
			if existing.Kind == domskill.KindBuiltin {
				targetDigest = builtinVersionDigest(SkillBundleVersion{InputChipsSchemaSnapshot: rawOrDefault(v.InputChipsSchemaSnapshot, emptyJSONArr), AgentCompatSnapshot: rawOrDefault(v.AgentCompatSnapshot, emptyJSONObj)})
			}
			if strings.EqualFold(targetDigest, entry.Version.ContentSHA256) {
				changed, finalizeErr := s.publishAndEnableImportedSkill(ctx, existing, &v, operatorID)
				if finalizeErr != nil {
					if v.Status == domskill.VersionStatusArchived {
						item.Status, item.Message = "conflict", "目标环境相同版本已归档，不能自动重新发布"
					} else {
						item.Message = safeBundleError(finalizeErr)
					}
					return item
				}
				if changed {
					item.Status, item.Message = "updated", "已补发布并启用"
				} else {
					item.Status, item.Message = "skipped", "目标环境已存在相同已发布版本，技能已启用"
				}
			} else {
				item.Status, item.Message = "conflict", "目标环境同版本内容不同，请在源环境提升版本号"
			}
			return item
		}
	}
	if s.packages == nil && (entry.Metadata.Kind == domskill.KindAgent || len(entry.Assets) > 0) {
		item.Message = "技能包/图片存储未配置，无法导入该技能"
		return item
	}

	categoryID, err := s.resolveBundleCategory(ctx, entry.Category)
	if err != nil {
		item.Message = safeBundleError(err)
		return item
	}
	labelIDs, err := s.resolveBundleLabels(ctx, entry.Labels)
	if err != nil {
		item.Message = safeBundleError(err)
		return item
	}
	if err := s.importBundleAssets(ctx, &entry, files); err != nil {
		item.Message = safeBundleError(err)
		return item
	}
	operator := operatorID
	created := existing == nil
	var importedVersion *domskill.SkillVersion
	if created {
		sk, autoVer, err := s.createSkill(ctx, domskill.CreateSkillInput{
			Code: entry.Code, Name: entry.Metadata.Name, Description: entry.Metadata.Description,
			UsageExample: entry.Metadata.UsageExample, UsageExampleImages: entry.Metadata.UsageExampleImages,
			IconURL: entry.Metadata.IconURL, Placeholder: entry.Metadata.Placeholder, SubmitLabel: entry.Metadata.SubmitLabel,
			Kind: entry.Metadata.Kind, BuiltinKey: entry.Metadata.BuiltinKey, ExecutionMode: entry.Metadata.ExecutionMode,
			ScopeKind: domskill.ScopePlatform, Source: entry.Metadata.Source, Visibility: entry.Metadata.Visibility,
			CategoryID: categoryID, LabelIDs: labelIDs, HostingModes: entry.Metadata.HostingModes,
			AgentCompat: entry.Version.AgentCompatSnapshot, InputChipsSchema: builtinInput(entry),
			DefaultAttached: entry.Metadata.DefaultAttached, DefaultPinned: entry.Metadata.DefaultPinned,
			SortOrder: entry.Metadata.SortOrder, CreatedBy: &operator,
		}, bundleCodePattern)
		if err != nil {
			item.Message = safeBundleError(err)
			return item
		}
		existing = sk
		if sk.MarketingVisible != entry.Metadata.MarketingVisible {
			if _, err := s.PatchSkill(ctx, sk.UUID, domskill.PatchSkillInput{MarketingVisible: &entry.Metadata.MarketingVisible, UpdatedBy: &operator}); err != nil {
				item.Message = safeBundleError(err)
				return item
			}
		}
		if autoVer != nil && autoVer.Version == entry.Version.Version {
			if builtinVersionDigest(SkillBundleVersion{InputChipsSchemaSnapshot: autoVer.InputChipsSchemaSnapshot, AgentCompatSnapshot: autoVer.AgentCompatSnapshot}) != entry.Version.ContentSHA256 {
				item.Status, item.Message = "conflict", "自动创建的 builtin 初始版本内容与 bundle 不一致"
				return item
			}
			importedVersion = autoVer
		}
	} else {
		labels := append([]int64(nil), labelIDs...)
		patch := domskill.PatchSkillInput{
			Name: &entry.Metadata.Name, Description: &entry.Metadata.Description, UsageExample: &entry.Metadata.UsageExample,
			UsageExampleImages: entry.Metadata.UsageExampleImages, IconURL: &entry.Metadata.IconURL,
			Placeholder: &entry.Metadata.Placeholder, SubmitLabel: &entry.Metadata.SubmitLabel,
			ExecutionMode: &entry.Metadata.ExecutionMode, Visibility: &entry.Metadata.Visibility, Source: &entry.Metadata.Source,
			CategoryID: categoryID, ClearCategory: categoryID == nil, LabelIDs: &labels,
			HostingModes: &entry.Metadata.HostingModes, AgentCompat: entry.Version.AgentCompatSnapshot,
			InputChipsSchema: builtinInput(entry), DefaultAttached: &entry.Metadata.DefaultAttached,
			DefaultPinned: &entry.Metadata.DefaultPinned, SortOrder: &entry.Metadata.SortOrder,
			MarketingVisible: &entry.Metadata.MarketingVisible, UpdatedBy: &operator,
		}
		if _, err := s.PatchSkill(ctx, existing.UUID, patch); err != nil {
			item.Message = safeBundleError(err)
			return item
		}
	}

	if err := s.applyBundleBilling(ctx, existing.ID, entry.Billing, operatorID); err != nil {
		item.Message = safeBundleError(err)
		return item
	}

	versionAlreadyCreated := importedVersion != nil
	if !versionAlreadyCreated {
		if entry.Metadata.Kind == domskill.KindAgent {
			v := resumableAgentVersion
			if v == nil {
				v, err = s.CreateAgentVersion(ctx, domskill.CreateAgentVersionInput{
					SkillUUID: existing.UUID, Version: entry.Version.Version, Changelog: entry.Version.Changelog,
					PackageURL: "pending://upload", InputChipsSchemaSnapshot: entry.Version.InputChipsSchemaSnapshot,
					AgentCompatSnapshot: entry.Version.AgentCompatSnapshot,
				})
				if err != nil {
					item.Message = safeBundleError(err)
					return item
				}
			}
			if _, err := s.UploadSkillPackage(ctx, UploadPackageInput{SkillUUID: existing.UUID, VersionUUID: v.UUID, Body: bytes.NewReader(files[entry.Version.PackagePath]), UpdatedBy: &operator}); err != nil {
				item.Message = safeBundleError(err)
				return item
			}
			importedVersion = v
		} else {
			v := &domskill.SkillVersion{
				SkillID: existing.ID, Version: entry.Version.Version, Status: domskill.VersionStatusDraft,
				Changelog: entry.Version.Changelog, InputChipsSchemaSnapshot: entry.Version.InputChipsSchemaSnapshot,
				AgentCompatSnapshot: entry.Version.AgentCompatSnapshot, GrayscalePct: 100,
				GrayscaleStrategy: domskill.GrayscaleTenantHash, GrayscaleAllowlist: []int64{},
			}
			if err := s.repo.CreateVersion(ctx, v); err != nil {
				item.Message = safeBundleError(err)
				return item
			}
			importedVersion = v
		}
	}
	if importedVersion == nil {
		item.Message = "导入版本状态异常"
		return item
	}
	if _, err := s.publishAndEnableImportedSkill(ctx, existing, importedVersion, operatorID); err != nil {
		item.Message = safeBundleError(err)
		return item
	}
	item.Status = "updated"
	if created {
		item.Status = "created"
	}
	item.Message = "已导入、发布并启用"
	return item
}

func (s *Service) publishAndEnableImportedSkill(ctx context.Context, skill *domskill.Skill, version *domskill.SkillVersion, operatorID int64) (bool, error) {
	changed := false
	switch version.Status {
	case domskill.VersionStatusDraft:
		pct := 100
		strategy := domskill.GrayscaleTenantHash
		operator := operatorID
		if _, err := s.PublishVersion(ctx, version.UUID, domskill.PublishVersionInput{
			GrayscalePct: &pct, GrayscaleStrategy: &strategy,
			GrayscaleAllowlist: []int64{}, PublishedBy: &operator,
		}); err != nil {
			return false, err
		}
		changed = true
	case domskill.VersionStatusPublished:
	case domskill.VersionStatusArchived:
		return false, apperr.ErrConflict.Withf("skill.bundle_version_archived")
	default:
		return false, apperr.ErrConflict.Withf("skill.bundle_version_status_invalid: %s", version.Status)
	}

	if skill.Status != domskill.StatusActive {
		status := domskill.StatusActive
		operator := operatorID
		if _, err := s.PatchSkill(ctx, skill.UUID, domskill.PatchSkillInput{Status: &status, UpdatedBy: &operator}); err != nil {
			return false, err
		}
		s.notifyf(ctx, "skills:%d", skill.ID)
		changed = true
	}
	return changed, nil
}

func parseAndValidateSkillBundle(body []byte) (*SkillBundleManifest, map[string][]byte, error) {
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		return nil, nil, fmt.Errorf("zip parse: %w", err)
	}
	if len(zr.File) == 0 || len(zr.File) > maxSkillBundleFiles {
		return nil, nil, fmt.Errorf("file count must be 1..%d", maxSkillBundleFiles)
	}
	files := make(map[string][]byte, len(zr.File))
	var total int64
	for _, f := range zr.File {
		if !isSafeBundlePath(f.Name) || f.FileInfo().IsDir() {
			return nil, nil, fmt.Errorf("unsafe file path %q", f.Name)
		}
		if _, exists := files[f.Name]; exists {
			return nil, nil, fmt.Errorf("duplicate file %q", f.Name)
		}
		total += int64(f.UncompressedSize64)
		if total > MaxSkillBundleBytes {
			return nil, nil, errors.New("uncompressed content exceeds limit")
		}
		rc, err := f.Open()
		if err != nil {
			return nil, nil, err
		}
		limit := int64(f.UncompressedSize64) + 1
		if f.Name == "manifest.json" && limit > maxSkillBundleManifest+1 {
			rc.Close()
			return nil, nil, errors.New("manifest too large")
		}
		buf, readErr := io.ReadAll(io.LimitReader(rc, limit))
		closeErr := rc.Close()
		if readErr != nil || closeErr != nil || uint64(len(buf)) != f.UncompressedSize64 {
			return nil, nil, fmt.Errorf("read file %q", f.Name)
		}
		files[f.Name] = buf
	}
	manifestBody, ok := files["manifest.json"]
	if !ok {
		return nil, nil, errors.New("manifest.json missing")
	}
	var manifest SkillBundleManifest
	// format_version gates breaking changes; unknown additive fields are ignored
	// so a v1 reader remains forward-compatible with newer v1 exporters.
	dec := json.NewDecoder(bytes.NewReader(manifestBody))
	if err := dec.Decode(&manifest); err != nil {
		return nil, nil, fmt.Errorf("manifest decode: %w", err)
	}
	if manifest.FormatVersion != SkillBundleFormatVersion {
		return nil, nil, fmt.Errorf("unsupported format_version %d", manifest.FormatVersion)
	}
	if len(manifest.Skills) == 0 || len(manifest.Skills) > MaxSkillBundleSkills {
		return nil, nil, fmt.Errorf("skills count must be 1..%d", MaxSkillBundleSkills)
	}
	seenCodes := make(map[string]bool, len(manifest.Skills))
	expectedFiles := map[string]bool{"manifest.json": true}
	for i := range manifest.Skills {
		e := &manifest.Skills[i]
		if !bundleCodePattern.MatchString(e.Code) || seenCodes[e.Code] {
			return nil, nil, fmt.Errorf("invalid or duplicate skill code %q", e.Code)
		}
		seenCodes[e.Code] = true
		if e.Metadata.Name == "" || !semverPattern.MatchString(e.Version.Version) {
			return nil, nil, fmt.Errorf("skill %s has invalid name or version", e.Code)
		}
		if err := validateBundleEntry(*e); err != nil {
			return nil, nil, fmt.Errorf("skill %s invalid: %w", e.Code, err)
		}
		for _, asset := range e.Assets {
			assetBody, ok := files[asset.Path]
			if !ok || !strings.EqualFold(sha256Hex(assetBody), asset.SHA256) {
				return nil, nil, fmt.Errorf("skill %s asset checksum mismatch: %s", e.Code, asset.Path)
			}
			maxAssetBytes := 1024 * 1024
			if asset.Kind == "usage_example" {
				maxAssetBytes = 5 * 1024 * 1024
			}
			if len(assetBody) == 0 || len(assetBody) > maxAssetBytes {
				return nil, nil, fmt.Errorf("skill %s asset size invalid: %s", e.Code, asset.Path)
			}
			expectedFiles[asset.Path] = true
		}
		if e.Metadata.Kind == domskill.KindAgent {
			expected := fmt.Sprintf("skills/%s/%s.zip", e.Code, e.Version.Version)
			if e.Version.PackagePath != expected || e.Version.PackageSHA256 == "" || e.Version.ContentSHA256 != e.Version.PackageSHA256 {
				return nil, nil, fmt.Errorf("skill %s package manifest invalid", e.Code)
			}
			pkg, ok := files[expected]
			if !ok || !strings.EqualFold(sha256Hex(pkg), e.Version.PackageSHA256) {
				return nil, nil, fmt.Errorf("skill %s package checksum mismatch", e.Code)
			}
			if _, err := readSkillMDFromZip(pkg); err != nil {
				return nil, nil, fmt.Errorf("skill %s package invalid: %w", e.Code, err)
			}
			if _, err := parseZipFiles(pkg); err != nil {
				return nil, nil, fmt.Errorf("skill %s package invalid: %w", e.Code, err)
			}
			expectedFiles[expected] = true
		} else {
			if e.Metadata.BuiltinKey == nil || *e.Metadata.BuiltinKey == "" || e.Version.PackagePath != "" || e.Version.PackageSHA256 != "" {
				return nil, nil, fmt.Errorf("skill %s builtin manifest invalid", e.Code)
			}
			if e.Version.ContentSHA256 != builtinVersionDigest(e.Version) {
				return nil, nil, fmt.Errorf("skill %s builtin checksum mismatch", e.Code)
			}
		}
	}
	for name := range files {
		if !expectedFiles[name] {
			return nil, nil, fmt.Errorf("unexpected file %q", name)
		}
	}
	return &manifest, files, nil
}

func validateBundleEntry(e SkillBundleEntry) error {
	if e.Metadata.Kind != domskill.KindAgent && e.Metadata.Kind != domskill.KindBuiltin {
		return errors.New("kind")
	}
	if e.Metadata.Kind == domskill.KindAgent && e.Metadata.ExecutionMode != domskill.ExecutionSyncInline {
		return errors.New("agent execution_mode")
	}
	if e.Metadata.Kind == domskill.KindBuiltin && e.Metadata.ExecutionMode != domskill.ExecutionSyncInline && e.Metadata.ExecutionMode != domskill.ExecutionAsyncFloating {
		return errors.New("builtin execution_mode")
	}
	if e.Metadata.Source != domskill.SourceInternal && e.Metadata.Source != domskill.SourceOpenSource && e.Metadata.Source != domskill.SourceThirdParty {
		return errors.New("source")
	}
	if e.Metadata.Visibility != domskill.VisibilityPrivate && e.Metadata.Visibility != domskill.VisibilityWorkspace && e.Metadata.Visibility != domskill.VisibilityTenant && e.Metadata.Visibility != domskill.VisibilityPlatform {
		return errors.New("visibility")
	}
	for _, mode := range e.Metadata.HostingModes {
		if mode != domskill.HostingPlatformManaged && mode != domskill.HostingHybrid {
			return errors.New("hosting_modes")
		}
	}
	if _, err := normalizeUsageExampleImages(e.Metadata.UsageExampleImages); err != nil {
		return errors.New("usage_example_images")
	}
	var usageImages []map[string]any
	if err := json.Unmarshal(e.Metadata.UsageExampleImages, &usageImages); err != nil {
		return errors.New("usage_example_images")
	}
	seenAssets := make(map[string]bool, len(e.Assets))
	seenAssetTargets := make(map[string]bool, len(e.Assets))
	for _, asset := range e.Assets {
		if seenAssets[asset.Path] || !isSafeBundlePath(asset.Path) || !strings.HasPrefix(asset.Path, "assets/"+e.Code+"/") ||
			(asset.Kind != "icon" && asset.Kind != "usage_example") || bundleContentTypeExt(asset.ContentType) == "" || len(asset.SHA256) != 64 {
			return errors.New("assets")
		}
		target := asset.Kind
		if asset.Kind == "usage_example" {
			target = fmt.Sprintf("%s:%d", asset.Kind, asset.Index)
		}
		if seenAssetTargets[target] || (asset.Kind == "usage_example" && (asset.Index < 0 || asset.Index >= len(usageImages))) {
			return errors.New("usage example asset index")
		}
		seenAssets[asset.Path] = true
		seenAssetTargets[target] = true
	}
	if !json.Valid(e.Version.InputChipsSchemaSnapshot) || !json.Valid(e.Version.AgentCompatSnapshot) {
		return errors.New("version snapshots")
	}
	if e.Category != nil {
		if !bundleCodePattern.MatchString(e.Category.Code) || e.Category.Name == "" ||
			(e.Category.CategoryKind != "" && e.Category.CategoryKind != domskill.CategoryFoundation && e.Category.CategoryKind != domskill.CategoryScenario) {
			return errors.New("category")
		}
	}
	seenLabels := make(map[string]bool, len(e.Labels))
	for _, label := range e.Labels {
		if !bundleCodePattern.MatchString(label.Code) || label.Name == "" || seenLabels[label.Code] {
			return errors.New("labels")
		}
		seenLabels[label.Code] = true
	}
	if e.Billing.BillingType != domskill.BillingTypeFree && e.Billing.BillingType != domskill.BillingTypePaid {
		return errors.New("billing_type")
	}
	if e.Billing.PricingMode != domskill.PricingModePerSkill && e.Billing.PricingMode != domskill.PricingModePerOperation {
		return errors.New("pricing_mode")
	}
	if e.Billing.BillingType == domskill.BillingTypePaid && (e.Billing.DefaultCreditsPerCall == nil || *e.Billing.DefaultCreditsPerCall < 0) {
		return errors.New("default price")
	}
	if len(e.Billing.Operations) > 200 {
		return errors.New("too many operations")
	}
	seenOps := make(map[string]bool, len(e.Billing.Operations))
	for _, op := range e.Billing.Operations {
		if !bundleCodePattern.MatchString(op.OperationCode) || op.OperationName == "" || seenOps[op.OperationCode] ||
			!json.Valid(op.InputSchema) || !json.Valid(op.OutputSchema) || (op.CreditsPerCall != nil && *op.CreditsPerCall < 0) {
			return errors.New("operations")
		}
		seenOps[op.OperationCode] = true
	}
	if e.Billing.BillingType == domskill.BillingTypePaid && e.Billing.PricingMode == domskill.PricingModePerOperation && len(e.Billing.Operations) == 0 {
		return errors.New("per_operation requires operations")
	}
	return nil
}

func (s *Service) findPlatformSkillByCode(ctx context.Context, code string) (*domskill.Skill, error) {
	for offset := 0; ; offset += 200 {
		rows, total, err := s.repo.ListSkills(ctx, domskill.ListFilter{ScopeKind: domskill.ScopePlatform, Keyword: code, Limit: 200, Offset: offset})
		if err != nil {
			return nil, err
		}
		for i := range rows {
			if rows[i].Code == code {
				return &rows[i], nil
			}
		}
		if len(rows) == 0 || int64(offset+len(rows)) >= total {
			break
		}
	}
	return nil, nil
}

func (s *Service) resolveBundleCategory(ctx context.Context, in *SkillBundleCategory) (*int64, error) {
	if in == nil {
		return nil, nil
	}
	rows, _, err := s.repo.ListCategories(ctx, domskill.DictListFilter{Keyword: in.Code, Limit: 1000})
	if err != nil {
		return nil, err
	}
	for _, c := range rows {
		if c.Code == in.Code {
			id := c.ID
			return &id, nil
		}
	}
	kind := in.CategoryKind
	if kind == "" {
		kind = domskill.CategoryScenario
	}
	c := &domskill.Category{Code: in.Code, Name: in.Name, CategoryKind: kind, Description: in.Description, SortOrder: in.SortOrder, Status: domskill.StatusActive}
	if err := s.repo.CreateCategory(ctx, c); err != nil {
		return nil, err
	}
	return &c.ID, nil
}

func (s *Service) resolveBundleLabels(ctx context.Context, in []SkillBundleLabel) ([]int64, error) {
	rows, _, err := s.repo.ListLabels(ctx, domskill.DictListFilter{Limit: 1000})
	if err != nil {
		return nil, err
	}
	byCode := make(map[string]int64, len(rows))
	for _, l := range rows {
		byCode[l.Code] = l.ID
	}
	ids := make([]int64, 0, len(in))
	for _, src := range in {
		if id, ok := byCode[src.Code]; ok {
			ids = append(ids, id)
			continue
		}
		l := &domskill.Label{Code: src.Code, Name: src.Name, Description: src.Description, SortOrder: src.SortOrder, Status: domskill.StatusActive}
		if err := s.repo.CreateLabel(ctx, l); err != nil {
			return nil, err
		}
		byCode[src.Code] = l.ID
		ids = append(ids, l.ID)
	}
	return ids, nil
}

func (s *Service) importBundleAssets(ctx context.Context, entry *SkillBundleEntry, files map[string][]byte) error {
	if len(entry.Assets) == 0 {
		return nil
	}
	if s.packages == nil {
		return errors.New("skill image store not configured")
	}
	type usageImage struct {
		StorageURI string `json:"storage_uri"`
		FileName   string `json:"file_name,omitempty"`
	}
	var images []usageImage
	if err := json.Unmarshal(entry.Metadata.UsageExampleImages, &images); err != nil {
		return err
	}
	for _, asset := range entry.Assets {
		prefix, limit := "skill-icons/", int64(1024*1024)
		if asset.Kind == "usage_example" {
			prefix, limit = "skill-example-images/", 5*1024*1024
		}
		uploaded, err := s.packages.UploadImage(ctx, bytes.NewReader(files[asset.Path]), asset.ContentType, prefix, limit)
		if err != nil {
			return err
		}
		if asset.Kind == "icon" {
			entry.Metadata.IconURL = uploaded.StorageURI
			continue
		}
		if asset.Index >= len(images) {
			return errors.New("usage example asset index outside metadata")
		}
		images[asset.Index].StorageURI = uploaded.StorageURI
		if images[asset.Index].FileName == "" {
			images[asset.Index].FileName = asset.FileName
		}
	}
	updated, err := json.Marshal(images)
	if err != nil {
		return err
	}
	entry.Metadata.UsageExampleImages = updated
	return nil
}

func bundleImageType(raw string) (string, string) {
	ext := strings.ToLower(path.Ext(strings.TrimPrefix(raw, "oss://")))
	switch ext {
	case ".png":
		return "image/png", ext
	case ".jpg", ".jpeg":
		return "image/jpeg", ".jpg"
	case ".gif":
		return "image/gif", ext
	case ".webp":
		return "image/webp", ext
	default:
		return "", ""
	}
}

func bundleContentTypeExt(contentType string) string {
	switch contentType {
	case "image/png":
		return ".png"
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	default:
		return ""
	}
}

func (s *Service) applyBundleBilling(ctx context.Context, skillID int64, in SkillBundleBilling, operatorID int64) error {
	if s.billing == nil {
		return nil
	}
	existing, _, err := s.billing.ListSkillOperations(ctx, skillID, dombilling.SkillOperationFilter{Limit: 500})
	if err != nil {
		return err
	}
	keep := make(map[string]bool, len(in.Operations))
	ops := make([]dombilling.SaveSkillPricingOperationEntry, 0, len(in.Operations))
	for _, op := range in.Operations {
		keep[op.OperationCode] = true
		ops = append(ops, dombilling.SaveSkillPricingOperationEntry{
			OperationCode: op.OperationCode, OperationName: op.OperationName, Description: op.Description,
			InputSchema: op.InputSchema, OutputSchema: op.OutputSchema, SortOrder: op.SortOrder, CreditsPerCall: op.CreditsPerCall,
		})
	}
	deleted := make([]string, 0)
	for _, op := range existing {
		if !keep[op.OperationCode] {
			deleted = append(deleted, op.OperationCode)
		}
	}
	return s.billing.SaveSkillPricingConfig(ctx, skillID, dombilling.SaveSkillPricingConfigInput{
		BillingType: in.BillingType, PricingMode: in.PricingMode, DefaultCreditsPerCall: in.DefaultCreditsPerCall,
		Operations: ops, DeletedOperationCodes: deleted, OperatorID: operatorID,
	})
}

func normalizeBundleUUIDs(in []string) ([]string, error) {
	if len(in) == 0 || len(in) > MaxSkillBundleSkills {
		return nil, apperr.ErrInvalidParams.Withf("skill.bundle_count_must_be_1_to_%d", MaxSkillBundleSkills)
	}
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, raw := range in {
		uuid := strings.TrimSpace(raw)
		if uuid == "" || seen[uuid] {
			return nil, apperr.ErrInvalidParams.Withf("skill.bundle_uuid_empty_or_duplicate")
		}
		seen[uuid] = true
		out = append(out, uuid)
	}
	return out, nil
}

func builtinInput(e SkillBundleEntry) []byte {
	if e.Metadata.Kind == domskill.KindBuiltin {
		return e.Version.InputChipsSchemaSnapshot
	}
	return emptyJSONArr
}

func rawOrDefault(raw, fallback []byte) json.RawMessage {
	if len(raw) == 0 || !json.Valid(raw) {
		return append(json.RawMessage(nil), fallback...)
	}
	return append(json.RawMessage(nil), raw...)
}

func builtinVersionDigest(v SkillBundleVersion) string {
	canonical := struct {
		Input  json.RawMessage `json:"input_chips_schema_snapshot"`
		Compat json.RawMessage `json:"agent_compat_snapshot"`
	}{canonicalRaw(v.InputChipsSchemaSnapshot, emptyJSONArr), canonicalRaw(v.AgentCompatSnapshot, emptyJSONObj)}
	body, _ := json.Marshal(canonical)
	return sha256Hex(body)
}

func canonicalRaw(raw, fallback []byte) json.RawMessage {
	raw = rawOrDefault(raw, fallback)
	var value any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&value); err != nil {
		return append(json.RawMessage(nil), fallback...)
	}
	body, err := json.Marshal(value)
	if err != nil {
		return append(json.RawMessage(nil), fallback...)
	}
	return body
}

func sha256Hex(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func isSafeBundlePath(name string) bool {
	return name != "" && !strings.Contains(name, "\\") && !strings.ContainsAny(name, "\x00\r\n") &&
		!strings.HasPrefix(name, "/") && path.Clean(name) == name && name != "." && !strings.HasPrefix(name, "../")
}

func writeBundleZipFile(zw *zip.Writer, name string, body []byte) error {
	h := &zip.FileHeader{Name: name, Method: zip.Deflate}
	h.SetModTime(time.Unix(0, 0).UTC())
	w, err := zw.CreateHeader(h)
	if err != nil {
		return err
	}
	_, err = w.Write(body)
	return err
}

func sameOptionalString(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

func safeBundleError(err error) string {
	if err == nil {
		return ""
	}
	if app, ok := apperr.AsError(err); ok {
		return app.Message
	}
	return "导入失败，请查看服务端日志"
}

func (s *Service) auditBundle(ctx context.Context, action string, operatorID int64, digest string, entries []SkillBundleEntry, results []ImportSkillBundleItem) {
	if s.audit == nil {
		return
	}
	codes := make([]string, 0, len(entries))
	for _, e := range entries {
		codes = append(codes, e.Code)
	}
	payload := map[string]any{
		"event_kind": "skill.bundle_" + action, "resource_kind": "skill_bundle", "operator_id": operatorID,
		"skill_count": len(entries), "skill_codes": codes, "bundle_sha256": digest,
	}
	if results != nil {
		payload["results"] = results
	}
	_ = s.audit.PublishWithTx(ctx, "audit.skill.bundle_"+action, 0, "skill-bundle-"+action+":"+digest, payload)
}
