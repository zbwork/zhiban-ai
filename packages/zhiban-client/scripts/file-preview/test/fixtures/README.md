# 视频预览测试素材

`preview.mp4` 是程序生成的无音轨 H.264/yuv420p 色条：128×72、12 fps、1 秒。用于测试真实视频解码、暂停、拖动、切换释放及失败回退，不是 AI 生视频产物，也不包含用户内容。

可用 FFmpeg 重新生成等价素材（不同版本的编码字节可能不同）：

```sh
ffmpeg -f lavfi -i 'testsrc=size=128x72:rate=12' -t 1 -c:v libx264 -pix_fmt yuv420p -movflags +faststart preview.mp4
```

渲染器测试使用此仓库内固定文件；重新生成不代表视频供应商或计费链路验收通过。
