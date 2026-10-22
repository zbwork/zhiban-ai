package app

import "context"

func (r *AppRepo) WorkspaceApps(ctx context.Context, accountID, tenantID int64) ([]map[string]any, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT COALESCE(c.name,'其他') AS category_name,
		        COALESCE(c.code,'uncategorized') AS category_code,
		        COALESCE(c.sort_order, 999999) AS category_order,
		        a.uuid::text, a.code, a.name, COALESCE(a.icon_url,''), COALESCE(a.description,''),
		        COALESCE(a.color,''), a.display_mode, a.launch_uri,
		        COALESCE(tas.sort_order, a.sort_order), a.id
		   FROM apps a
		   JOIN tenant_app_settings tas
		     ON tas.app_id = a.id
		    AND tas.tenant_id = $1
		    AND tas.is_enabled = true
		    AND tas.is_universal = true
		   LEFT JOIN app_category c
		     ON c.id = a.category_id
		    AND (c.tenant_id IS NULL OR c.tenant_id = $1)
		  WHERE a.deleted_at IS NULL
		    AND a.status = 'active'
		    AND COALESCE(a.usage_scope,'all') IN ('all','end_user')
		    AND (
		      a.tenant_id = $1
		      OR (
		        a.tenant_id IS NULL
		        AND a.is_system = true
		        AND a.metadata @> '{"open_to_tenants": true}'::jsonb
		      )
		    )
		  ORDER BY category_order, category_name, COALESCE(tas.sort_order, a.sort_order), a.id`,
		tenantID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type categoryBucket struct {
		name  string
		code  string
		apps  []map[string]any
		index int
	}
	buckets := make([]categoryBucket, 0)
	bucketByCode := map[string]int{}
	for rows.Next() {
		var categoryName, categoryCode, uuid, code, name, icon, description, color, displayMode, launchURI string
		var categoryOrder, order int
		var appID int64
		if err := rows.Scan(&categoryName, &categoryCode, &categoryOrder, &uuid, &code, &name, &icon, &description,
			&color, &displayMode, &launchURI, &order, &appID); err != nil {
			return nil, err
		}
		idx, ok := bucketByCode[categoryCode]
		if !ok {
			idx = len(buckets)
			bucketByCode[categoryCode] = idx
			buckets = append(buckets, categoryBucket{
				name:  categoryName,
				code:  categoryCode,
				apps:  []map[string]any{},
				index: categoryOrder,
			})
		}
		buckets[idx].apps = append(buckets[idx].apps, map[string]any{
			"uuid":         uuid,
			"code":         code,
			"name":         name,
			"icon":         icon,
			"description":  description,
			"redirectType": "webview",
			"redirectUrl":  launchURI,
			"displayMode":  displayMode,
			"order":        order,
			"color":        color,
			"todoCount":    0,
			"webview":      launchURI,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(buckets))
	for _, b := range buckets {
		out = append(out, map[string]any{
			"categoryName": b.name,
			"category":     b.code,
			"order":        b.index,
			"apps":         b.apps,
		})
	}
	return out, nil
}
