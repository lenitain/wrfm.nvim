# wrfm.nvim 用户测试手册

## 安装

### lazy.nvim

```lua
{
  "your-username/wrfm.nvim",
  opts = {},
}
```

### pckr.nvim

```lua
require("pckr").add("your-username/wrfm.nvim")
```

### 手动

把 `lua/`、`plugin/`、`doc/` 三个目录复制到你的 Neovim runtimepath 下，然后执行 `:helptags ALL`。

---

## 配置（全部可选）

```lua
require("wrfm").setup({
  -- 画布大小（braille 字符数），nil = 自动按窗口百分比
  default_width = nil,
  default_height = nil,

  -- 默认视角
  default_pitch = 30,        -- 俯仰角（度），0 = 正面，90 = 俯视
  default_distance = nil,    -- 相机距离，nil = 自动 fit

  -- 动画
  default_auto_spin = true,  -- 打开后自动旋转
  default_spin_speed = 0.02, -- 旋转速度（弧度/帧）
  fps = 30,                  -- 动画帧率

  -- 文件热重载
  default_watch = true,      -- 编辑 .wrfm 文件后自动更新预览

  -- 内联预览（在缓冲内显示线框，非浮窗）
  integrations = {
    wrfm = {
      enabled = true,                -- 打开 .wrfm 文件时自动显示内联预览
      clear_in_insert_mode = false,  -- 插入模式时隐藏预览
      only_render_at_cursor = false, -- 只在光标附近显示
      cursor_mode = "popup",         -- "popup" 浮窗 或 "inline" 行内
      filetypes = { "wrfm" },
    },
  },
})
```

**零配置即可用**——不调 `setup()` 也能工作。

---

## 测试场景

### 场景 1：基本浮窗查看

**操作**：打开 Neovim，执行：

```vim
:Wrfm /path/to/model.wrfm
```

如果没有 .wrfm 文件，用仓库自带的测试模型：

```vim
:Wrfm ~/.local/share/nvim/lazy/wrfm.nvim/tests/fixtures/models/cube.wrfm
```

**预期**：
- 屏幕中央出现一个带圆角边框的浮动窗口
- 窗口标题显示文件名（如 `cube.wrfm`）
- 窗口内容是 braille 字符画出的 3D 线框
- 线框在自动旋转（如果 `default_auto_spin = true`）

**交互验证**：
- 执行 `:WrfmList` → 应看到一行：`model-1  float  spin=true  /path/to/cube.wrfm`
- 执行 `:WrfmClear` → 浮窗关闭

---

### 场景 2：内联预览（缓冲内显示）

**操作**：用 Neovim 打开一个 .wrfm 文件：

```vim
:e ~/.local/share/nvim/lazy/wrfm.nvim/tests/fixtures/models/anvil.wrfm
```

**预期**：
- 如果 `integrations.wrfm.enabled = true`（默认），缓冲顶部自动出现一截 braille 线框预览
- 预览下方是 .wrfm 原始文本（`wrfm 1`、`vertices ...`、`v ...`、`e ...`）
- 预览随缓冲滚动——往下滚，预览跟着走
- 线框在旋转

**手动开关**（如果 `enabled = false`）：

```vim
:WrfmHere       " 在当前缓冲附加预览
:WrfmDetach     " 移除预览
```

**交互验证**：
- 在预览下方编辑 .wrfm 文本（比如改一个顶点坐标），保存 → 预览自动更新（热重载）
- 执行 `:WrfmList` → 应看到 `model-N  inline  spin=true  /path/to/anvil.wrfm`
- 执行 `:WrfmDetach` → 预览消失，原文不受影响

---

### 场景 3：同时开多个查看器

**操作**：

```vim
:Wrfm path/to/cube.wrfm
:Wrfm path/to/anvil.wrfm
:Wrfm path/to/bicycle.wrfm
```

**预期**：三个浮窗同时显示，各自独立旋转

**交互验证**：
- `:WrfmList` → 三行，各自 id 不同
- `:WrfmClear model-2` → 只关第二个，其余继续
- `:WrfmClear` → 全部关闭

---

### 场景 4：热重载

**操作**：

1. 打开预览：`:Wrfm /tmp/test.wrfm`（先确保文件存在）
2. 在另一个终端或 Neovim 分屏中编辑 `/tmp/test.wrfm`，改几行顶点坐标，保存
3. 回到预览窗口

**预期**：预览在 ~150ms 内自动更新为新形状，旋转角度不变

**验证边界**：
- 故意写入语法错误的 .wrfm 内容（比如删一行 `vertices`），保存 → 预览保持上一次正常帧不变，底部出现一条警告通知
- 恢复正确内容，保存 → 预览自愈

---

### 场景 5：旋转控制

**操作**：打开预览后，在 Neovim 命令行执行：

```vim
:lua require("wrfm").current:set_spin(false)    " 停止旋转
:lua require("wrfm").current:set_spin(true)     " 恢复旋转
:lua require("wrfm").current:set_pitch(0)       " 正面视角
:lua require("wrfm").current:set_pitch(90)      " 俯视
:lua require("wrfm").current:set_pitch(30)      " 恢复默认
:lua require("wrfm").current:set_distance(2)    " 拉近（小值=近）
:lua require("wrfm").current:set_distance(nil)  " 恢复自动 fit
```

**预期**：每次调用后预览立即重绘，反映新视角

---

### 场景 6：健康检查

```vim
:checkhealth wrfm
```

**预期输出**（全部绿色 ✅）：
- Neovim 版本 >= 0.11
- 渲染管线冒烟通过
- 解析器冒烟通过
- uv timer 可用
- 当前配置摘要
- wrfm CLI 可用性（可选）

---

### 场景 7：全局开关

```vim
:lua require("wrfm").disable()    " 隐藏所有预览，停止动画
:lua require("wrfm").is_enabled() " → false
:lua require("wrfm").enable()     " 恢复所有预览
```

**预期**：`disable()` 后所有浮窗关闭、内联预览消失、旋转停止；`enable()` 后全部恢复原状。

---

### 场景 8：诊断报告

```vim
:WrfmReport
```

**预期**：弹出一个浮窗，显示：
- Neovim 版本、操作系统
- 当前配置
- 所有活跃模型的列表（id、模式、路径、尺寸、视角、旋转状态）

---

## 常见问题排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 打开 .wrfm 没有内联预览 | `integrations.wrfm.enabled = false` | 在 setup 中设为 true，或手动 `:WrfmHere` |
| 预览不动 | `default_auto_spin = false` | 设为 true，或 `:lua require("wrfm").current:set_spin(true)` |
| 编辑文件后预览没更新 | `default_watch = false` 或文件写入方式问题 | 设 `watch = true`；确保编辑器保存时触发了文件系统事件 |
| 浮窗挡住编辑区 | 正常行为 | `:WrfmClear` 关闭，或用内联预览替代 |
| 终端里看到乱码 | 终端不支持 Unicode braille | 换一个支持 Unicode 的终端（几乎所有现代终端都支持） |
| `:checkhealth wrfm` 报错 | Neovim 版本太低 | 升级到 >= 0.11 |

---

## 可观测性清单

用这个清单确认插件的每个行为都可观察、可交互：

- [ ] `:Wrfm <file>` 打开浮窗，内容是 braille 线框
- [ ] 浮窗在旋转
- [ ] `:WrfmList` 列出当前模型
- [ ] `:WrfmClear` 关闭浮窗
- [ ] 打开 .wrfm 文件时自动出现内联预览
- [ ] 内联预览随缓冲滚动
- [ ] 编辑 .wrfm 文件后预览自动更新
- [ ] `:WrfmHere` / `:WrfmDetach` 手动控制内联预览
- [ ] `set_spin(false)` 停止旋转，`set_spin(true)` 恢复
- [ ] `set_pitch()` 改变视角
- [ ] `set_distance()` 改变远近
- [ ] `disable()` 隐藏一切，`enable()` 恢复
- [ ] `:checkhealth wrfm` 全绿
- [ ] `:WrfmReport` 显示诊断信息
- [ ] 多个模型同时存在，独立控制
