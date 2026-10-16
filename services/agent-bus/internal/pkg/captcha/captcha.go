// Package captcha 提供图形验证码生成与校验。
//
// 实现：5 位 (数字+大写字母, 排除 0/1/I/O/L 等易混字符) + base64 PNG，
// 用 basicfont.Face7x13 渲染，每字符独立随机颜色 + 干扰线/噪点，提升识别难度。
// 校验大小写不敏感。值缓存在 Redis (key 前缀 agbus:auth:captcha:{captchaId})。
package captcha

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"math/big"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	codeLen = 5
	ttl     = 5 * time.Minute
	keyPfx  = "agbus:auth:captcha:"

	// 字符集：去掉易混的 0/O/1/I/L/2/Z 中部分。
	// 保留：数字 23456789，字母 ABCDEFGHJKMNPQRSTUVWXY（无 I/L/O/Z）。
	charset = "23456789ABCDEFGHJKMNPQRSTUVWXY"
)

// Captcha 是验证码服务。
type Captcha struct {
	rdb *redis.Client
}

// Result 是生成结果。
type Result struct {
	CaptchaID    string `json:"captchaId"`
	CaptchaImage string `json:"captchaImage"` // data:image/png;base64,...
}

// New 构造 captcha 服务。
func New(rdb *redis.Client) *Captcha { return &Captcha{rdb: rdb} }

// Generate 生成一个验证码并缓存到 Redis。
func (c *Captcha) Generate(ctx context.Context) (*Result, error) {
	code := randomCode(codeLen)
	id, err := randomID()
	if err != nil {
		return nil, err
	}
	img := renderImage(code)
	dataURI := "data:image/png;base64," + base64.StdEncoding.EncodeToString(img)

	if err := c.rdb.Set(ctx, keyPfx+id, strings.ToUpper(code), ttl).Err(); err != nil {
		return nil, err
	}
	return &Result{CaptchaID: id, CaptchaImage: dataURI}, nil
}

// Verify 校验并删除(一次性)。返回 ok=true 表示通过。大小写不敏感。
func (c *Captcha) Verify(ctx context.Context, id, code string) (bool, error) {
	if id == "" || code == "" {
		return false, nil
	}
	key := keyPfx + id
	got, err := c.rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !strings.EqualFold(got, code) {
		return false, nil
	}
	_ = c.rdb.Del(ctx, key).Err()
	return true, nil
}

func randomCode(n int) string {
	b := make([]byte, n)
	max := big.NewInt(int64(len(charset)))
	for i := range b {
		v, _ := rand.Int(rand.Reader, max)
		b[i] = charset[v.Int64()]
	}
	return string(b)
}

func randomID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), nil
}

// 调色板：中等饱和、对深色字符可读。
var palette = []color.RGBA{
	{0x1f, 0x6f, 0xeb, 0xff}, // blue
	{0xd9, 0x36, 0x4f, 0xff}, // red
	{0x10, 0x84, 0x4a, 0xff}, // green
	{0xb5, 0x60, 0x14, 0xff}, // orange
	{0x6f, 0x42, 0xc1, 0xff}, // purple
	{0x07, 0x6f, 0x83, 0xff}, // teal
	{0xc4, 0x4d, 0xa8, 0xff}, // pink
	{0x3a, 0x3a, 0x3a, 0xff}, // dark gray
}

func randInt(n int) int {
	v, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0
	}
	return int(v.Int64())
}

func pickColor() color.RGBA {
	return palette[randInt(len(palette))]
}

// renderImage 以 basicfont.Face7x13 为字模，按 scale 倍放大，每个字符
// 独立随机颜色，叠加少量干扰线与噪点。
func renderImage(code string) []byte {
	const (
		scale  = 4
		charW  = 7 * scale  // 28
		charH  = 13 * scale // 52
		padX   = 14
		padY   = 8
		gap    = 6
		height = charH + padY*2 // 68
	)
	width := padX*2 + charW*len(code) + gap*(len(code)-1)
	rgba := image.NewRGBA(image.Rect(0, 0, width, height))
	draw.Draw(rgba, rgba.Bounds(), &image.Uniform{C: color.RGBA{0xf6, 0xf8, 0xfb, 0xff}}, image.Point{}, draw.Src)

	x := padX
	for _, ch := range code {
		dy := randInt(7) - 3 // 轻微纵向抖动
		drawScaledGlyph(rgba, byte(ch), x, padY+dy, scale, pickColor())
		x += charW + gap
	}

	addInterference(rgba, width, height)

	var buf bytes.Buffer
	_ = png.Encode(&buf, rgba)
	return buf.Bytes()
}

// drawScaledGlyph 把 basicfont.Face7x13 的一个 7x13 字模放大 scale 倍画到 dst。
func drawScaledGlyph(dst *image.RGBA, ch byte, originX, originY, scale int, c color.RGBA) {
	tmp := image.NewRGBA(image.Rect(0, 0, 7, 13))
	d := &font.Drawer{
		Dst:  tmp,
		Src:  &image.Uniform{C: c},
		Face: basicfont.Face7x13,
		Dot:  fixed.P(0, 10),
	}
	d.DrawBytes([]byte{ch})

	for y := 0; y < 13; y++ {
		for x := 0; x < 7; x++ {
			r, _, _, a := tmp.At(x, y).RGBA()
			if a == 0 {
				continue
			}
			_ = r
			for sy := 0; sy < scale; sy++ {
				for sx := 0; sx < scale; sx++ {
					dst.Set(originX+x*scale+sx, originY+y*scale+sy, c)
				}
			}
		}
	}
}

// addInterference 叠加 2 条贝塞尔近似干扰线 + 稀疏噪点。
func addInterference(rgba *image.RGBA, w, h int) {
	for i := 0; i < 2; i++ {
		c := pickColor()
		x0 := randInt(w / 4)
		y0 := randInt(h)
		x1 := w - randInt(w/4)
		y1 := randInt(h)
		drawLine(rgba, x0, y0, x1, y1, c)
	}
	n := (w * h) / 80
	for i := 0; i < n; i++ {
		rgba.Set(randInt(w), randInt(h), pickColor())
	}
}

func drawLine(img *image.RGBA, x0, y0, x1, y1 int, c color.RGBA) {
	dx := abs(x1 - x0)
	dy := -abs(y1 - y0)
	sx := step(x0, x1)
	sy := step(y0, y1)
	err := dx + dy
	for {
		img.Set(x0, y0, c)
		img.Set(x0, y0+1, c)
		if x0 == x1 && y0 == y1 {
			return
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0 += sx
		}
		if e2 <= dx {
			err += dx
			y0 += sy
		}
	}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func step(a, b int) int {
	if a < b {
		return 1
	}
	if a > b {
		return -1
	}
	return 0
}

// String 仅用于错误信息或日志。
func (r *Result) String() string {
	return fmt.Sprintf("captcha[%s]", r.CaptchaID)
}
