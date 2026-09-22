# AnimationSource 时序研究记录

本文记录 `lua/cda/playback/animation_source.lua` 的设计依据、开发中暴露的
时序问题与日志证据。后续代码注释中若需引用细节，指向本文档对应章节即可。

---

## 一、两个 pos 的关系

所有设计都建立在这一节的关系式上。

```

bonePos = entPos + boneLocalOffset

```

- `entPos = self._Ent:GetPos()`
  实体原点世界坐标。根运动机制下它是**锚点**——`_ApplyRootMotion` 执行前
  全程不变。
- `bonePos = self._Ent:GetBonePosition(_AnchorID)`
  骨骼世界坐标。视觉上真正在哪儿由它表达。
- `boneLocalOffset`
  骨骼在模型空间的偏移。由动画驱动，每帧在变。

`boneLocalOffset` 就是 Blender 里"根骨在动画里走、Object 不动"这段位移
在 Source 引擎里的直接体现。它同时含水平与垂直两个分量：

- **水平分量**——`_ApplyRootMotion` 要转移的对象（§三）
- **垂直分量**——动画自身高度起伏，不进 z 修正（§四）

### 日志证据：`entPos` 不动、`bonePos` 漂移

来自一次未修复的运行。播放期间 `entPos` 全程固定，`bonePos` 从起点一路
漂到远处：

```

tick t=35.445 entPos=-12.02 -51.69 -148.00 bonePos=-23.26 -52.80 -141.25
tick t=35.955 entPos=-12.02 -51.69 -148.00 bonePos=-12.94 -51.34 -143.20
tick t=51.000 entPos=-12.02 -51.69 -148.00 bonePos=200.96 -52.77 -142.96

```

`entPos` 全程 `(-12.02, -51.69, -148.00)`——正是锚点语义的直接体现。
`bonePos` 从 `-23.26` 走到 `200.96`——横向漂移约 224 单位，这就是
`boneLocalOffset` 水平分量在一轮里的累积。

---

## 二、不做任何干预时的三种现象

### 2.1 循环处骨骼跳跃

**现象**：一轮播完，`SetAnimation` 把动画归到第 0 帧，骨骼世界位置从
`e1 + L1` 瞬间跳回 `e1 + L0`。视觉上"一顿"。

**机制**：

- 播放中 `boneLocalOffset` 从 `L0` 连续演化到 `L1`
- `entPos` 固定为 `e1`，所以 `bonePos` 从 `e1 + L0` 漂到 `e1 + L1`
- 循环时 `boneLocalOffset` 归零到 `L0`，`bonePos` 突跳回 `e1 + L0`

**水平方向是主症状**——垂直方向 `L0.z` 与 `L1.z` 通常接近，跳变小。

### 2.2 陷地

**现象**：骨骼嵌入地面以下。

**机制**：`boneLocalOffset.z` 由动画决定（骨骼相对实体原点的高度）。当
骨骼水平漂移到地形较高处，`bonePos.z` 不变但 `groundZ` 上升——`bonePos.z
< groundZ`，视觉上骨骼埋进地面。

平坦地形不会出现——`groundZ` 处处相等，无相对高度错配。

### 2.3 悬空

**现象**：骨骼悬在地面上方。

**机制**：与陷地对称。骨骼水平漂移到地形较低处，`groundZ` 下降——`bonePos.z

> groundZ`，视觉上骨骼悬空。

平坦地形同样不会出现。

### 2.4 归纳

三种现象同一根因：

> **`entPos` 是固定锚点，但视觉上真正在哪儿由 `bonePos` 表达，而 `bonePos`
> 每帧在变。**

- 跳跃 = `bonePos` 在循环点的**时间突变**
- 陷地/悬空 = `bonePos` 与地形在**空间上不对齐**

对应两条独立通道：

| 现象        | 通道 | 处理                      |
| ----------- | ---- | ------------------------- |
| 循环处跳跃  | 水平 | `_ApplyRootMotion`（§三） |
| 陷地 / 悬空 | 垂直 | `_TraceGround`（§四）     |

---

## 三、水平通道：`_ApplyRootMotion`

### 3.1 目标

让下一轮动画的第 0 帧骨骼世界位置，与本轮末帧骨骼世界位置**水平对齐**。
视觉上循环接缝处骨骼不跳。

### 3.2 方案

一轮结束时：

```lua
delta2D = (bonePos_end - _StartPos) 的水平分量
entPos  = entPos + delta2D
```

`_StartPos` 在本轮起点处采样（见 §五 时序），是骨骼世界坐标。

### 3.3 为什么

下一轮 `SetAnimation` 后，`boneLocalOffset` 从 `L1` 归到 `L0`。若 `entPos`
不动，新的 `bonePos` 就是 `e1 + L0`，与 `e1 + L1` 差 `L1 - L0`——这就是
跳跃量。

把 `entPos` 加上 `L1 - L0` 的水平分量，新的 `bonePos` 起点变为：

```
(e1 + delta2D) + L0  =  e1 + L0 + (L1 - L0) 的水平分量
                     =  e1 + L0 + L1_h - L0_h
```

若 `L0_h ≈ 0`（第 0 帧骨骼在原点附近），则新的 `bonePos` 水平分量 ≈
`e1 + L1_h`，与 `bonePos_end` 对齐。

### 3.4 为什么只取水平分量

垂直方向由 §四 独立处理。若这里也带 z，会与地形跟随叠加——z 双重修正。

### 3.5 日志证据

**未修复版本（坐标错配，见 §五）**：

```
loop-before  entPos= -12.02  -51.69 -148.00  bonePos=201.79 -52.90 -142.79
loop-after   entPos= 189.24 -104.60 -148.00  bonePos=201.79 -52.90 -142.79
```

`entPos` 的变化量 `(201.26, -52.90)`——与 `bonePos - _StartPos` 一致，
但 `_StartPos` 是错的（模型空间 `(0.53, 0)` 而非世界空间
`(-11.49, -51.69)`，见 §五）。结果 `entPos` 落到 `(189.24, -104.60)`，
与 `bonePos` 水平位置对不上。

**修复后应有的状态**：

```
loop-before  entPos= -12.02  -51.69 -148.00  bonePos=201.79 -52.90 -142.79
loop-after   entPos= 201.79  -52.90 -148.00  bonePos=201.79 -52.90 -142.79
                                ↑ 水平分量对齐 ↑
```

`loop-after` 的 `entPos` 水平分量等于 `loop-before` 的 `bonePos` 水平
分量。下一轮第 0 帧的骨骼世界位置就与该终点对齐——循环接缝无缝。

---

## 四、垂直通道：`_TraceGround`

### 4.1 目标

让 `bonePos.z` 跟随地形高度。骨骼在地形高处不下陷，地形低处不悬空。

### 4.2 方案

每帧从骨骼位置向下打射线测地面高度，用基线公式算目标 z：

```lua
z = _BaseEntZ + (groundZ - _BaseGroundZ)
```

- `_BaseGroundZ` / `_BaseEntZ`——本轮起点处采样，代表"同一瞬间的 (地面,
  实体) 快照"
- `groundZ`——当前帧射线命中的地面高度
- 若本轮起点射线 miss（悬空），基线留 nil，下一次成功 trace 时惰性建立

### 4.3 为什么参考点是骨骼位置，不是实体位置

**根运动机制下 `entPos` 在循环内是锚点**（§一、§三），`_ApplyRootMotion`
执行前全程不变。用它当射线起点，等于假设"视觉对象不动"——与 draw 场景
矛盾。

视觉上真正在哪儿由 `bonePos` 表达：`bonePos = e1 + boneLocalOffset`，每帧
在变。射线从 `bonePos` 出发，捕捉的才是视觉立足点下方的地面。

这条约定与 §一 的关系式直接对应。

### 4.4 为什么用基线，不用差分

**差分形式**（每帧 `z += g[i] - g[i-1]`）：

- 等价于积分。浮点上 O(N·eps) 累积误差。
- 依赖"上一帧 z 与上一帧 g 是同一时刻的一致状态"——任何外部改 z 都会让
  下一帧 diff 出错。

**基线形式**（`z = _BaseEntZ + (g - _BaseGroundZ)`）：

- 每帧独立计算，无累积。
- 对扰动免疫——只要基线正确，每帧结果都正确。
- 代价：多存一个 `_BaseEntZ`。

### 4.5 为什么动画自身的垂直起伏不污染信号

骨骼在局部空间上下浮动时，射线起点随之浮动，但地面高度不变——`groundZ`
不变，`z` 不变。所以动画自身的垂直起伏不产生 z 修正。

只有**地形本身变化**（骨骼水平漂移到不同地面高度）才产生 z 修正。这正是
我们想要的语义。

### 4.6 `GROUND_EPSILON`

**症状**：静态地面循环时 `entPos.z` 从 `-148.000000` 漂到 `-148.000092`
（~30 tick）。

**根因**：光线在不同 XY 命中同 brush 不同面时，`HitPos.z` 抖动约 1e-5
单位。基线公式忠实反映这个抖动。

**缓解**：给 `_TraceGround` 加阈值——地形高度变化低于此值视为噪声：

```lua
local GROUND_EPSILON = 0.01

local diff = groundZ - self._BaseGroundZ
if math.abs(diff) < GROUND_EPSILON then return end
```

0.01 远大于噪声量级（1e-5），远小于任何有意义的台阶高度（≥1 单位）。

---

## 五、干预过程中的时序问题

以上三节是**正确性设计**。本节记录实现过程中暴露的**时序陷阱**——不涉及
算法本身，只涉及"在什么时刻做这些操作"。

### 5.1 `_StartPos` 采样到模型空间坐标

#### 症状

第一轮 `_ApplyRootMotion` 计算的水平增量完全错误——方向偏 12 单位 X、
52 单位 Y。第二轮起 `entPos` 漂移到远离起点的地方。

#### 日志证据

```
tick  t=35.190  entPos=-12.02 -51.69 -148.00  bonePos= 0.53  0.00  38.56  ← 模型空间
tick  t=35.445  entPos=-12.02 -51.69 -148.00  bonePos=-23.26 -52.80 -141.25  ← 世界空间
```

同一 `GetBonePosition` 调用，返回两种坐标系。`t=35.190` 的 `(0.53, 0,
38.56)` 就是骨骼在模型空间的偏移——参考 §一 的关系式。

#### 根因

`SetPos` 只更新 `m_vecOrigin`。骨骼世界坐标由 `m_rgflCoordinateFrame ×
骨骼局部矩阵` 算出——`m_rgflCoordinateFrame` 在实体位置被标记变化后的
**下一帧末**才由引擎重算。

重算前调用 `GetBonePosition`，返回的数值以旧原点为基准——等价于模型空间。

#### 修复

`acquireEntity` 里把 `SetPos` / `SetAngles` 移到 `Spawn` 之前：

```lua
local ent = ents.Create("prop_dynamic")
ent:SetModel(modelName)
if pos then ent:SetPos(pos) end     -- ← Spawn 之前
if ang then ent:SetAngles(ang) end
ent:Spawn()                          -- 引擎基于新 m_vecOrigin 初始化骨骼矩阵
```

**`Spawn` 是引擎"给实体建立骨骼世界矩阵"的时刻**，它读取当前的
`m_vecOrigin`。在 `Spawn` 之前设 `SetPos`，骨骼矩阵一次到位，无需额外一帧。

#### 配套：`Track` 增加位置字段

```lua
---@class Track
---@field Pos Vector @模型放置位置
---@field Ang Angle? @模型放置角度，默认 Angle(0, 0, 0)
```

调用方在 `New` 时就指定位置，避免"在错误时机 SetPos"的陷阱。

#### 修复后的预期日志

```
loop init  bonePos=(-11.49 -51.69 -109.44)  entPos=(-12.02 -51.69 -148.00)
           baseGroundZ=-148  baseEntZ=-148
```

`bonePos - entPos = (0.53, 0, 38.56)`——正好是模型空间里骨盆相对原点的偏移。

### 5.2 `_EndTime` 只在 `New` 时写一次

#### 症状

第一轮播完后动画消失。

#### 根因

`_EndTime` 在 `_TrySetupSequence`（即 `New` 时）只写一次。循环重播走
`Play`，但 `Play` 未更新 `_EndTime`。第二轮开始每帧 `now >= _EndTime`
为真，`_Think` 每帧触发 `Play`，每帧重播——动画永远停在第 0 帧。

#### 修复

把"内容时长"和"结束时刻"分离：

- `_Duration`——常量，`New` 时确定，代表"内容播完需要多久"
- `_EndTime`——派生值，每次 `Play` 重算（`CurTime() + _Duration`）

```lua
function AnimationSource:_TrySetupSequence(track)
    self._Duration = track.Duration or sequenceDuration or math.huge
end

function AnimationSource:Play()
    self._EndTime = CurTime() + self._Duration
end
```

### 5.3 `ResetSequence + SetCycle(0)` 不循环

#### 症状

用 `ResetSequence(id)` + `ResetSequenceInfo()` + `SetCycle(0)` 播动画，
播完停在最后一帧，不循环。

#### 根因

这组 Lua API 在 `prop_dynamic` 上的行为不完全等价于 `Fire("SetAnimation")`。
`ResetSequenceInfo` 重置内部时间，`SetCycle(0)` 在某些情况下会把 cycle
锁住不让引擎推进。

#### 修复

走 EDAE2 OneShot 验证过的路径——实体 IO 通道：

```lua
self._Ent:Fire("SetPlaybackRate", 1)
self._Ent:Fire("SetAnimation", self._SequenceName, 0)
```

`SetAnimation` 接收动画名字符串，从头播放，循环由引擎按序列 flags 处理。

#### 代价：`timer.Simple(0, ...)`

`Fire` 走 IO 队列，帧末才生效。`_TryInitLoop` 里的 `GetBonePosition` 必须
等新序列生效才能拿到第 0 帧的骨骼位置——同步调用会读到旧序列的末帧位置。

`timer.Simple(0, ...)` 的回调在下一帧开始触发——晚于帧末 IO 处理，早于
任何后续业务代码。这是最早的安全时机。

**注意**：在 §5.1 修复之前，这个 `timer.Simple(0, ...)` 需要两层，因为
`SetPos` 也需要等骨骼矩阵重算。§5.1 修复后（`SetPos` 在 `Spawn` 之前），
单层足够。

### 5.4 修复后的完整时序

```
帧 N   t=T_click    TOOL:LeftClick
  │                  ├─ AnimationSource:New(track)
  │                  │    └─ _TrySetupEntity → acquireEntity(modelName, track.Pos)
  │                  │       ├─ ents.Create
  │                  │       ├─ SetModel
  │                  │       ├─ SetPos(track.Pos)  ← Spawn 之前
  │                  │       └─ Spawn()            骨骼矩阵一次到位
  │                  ├─ source:Play()
  │                  │    ├─ Fire("SetPlaybackRate", 1)    → IO 队列
  │                  │    ├─ Fire("SetAnimation", name, 0) → IO 队列
  │                  │    └─ timer.Simple(0, cb)           → timer 队列
  │                  └─ 打印 "playing"
  │
帧 N 末             引擎处理 IO 队列 → 动画切到第 0 帧
  │
帧 N+1  t≈35.190    cb 触发 → _TryInitLoop
  │                  ├─ GetBonePosition → 世界空间 ✓
  │                  ├─ _StartPos = 世界坐标
  │                  ├─ traceGroundZ → 从世界坐标向下 → 命中
  │                  └─ _BaseGroundZ / _BaseEntZ 建立
  │
帧 N+1 起           _Think 正常循环
  │                  ├─ _TraceGround（每帧，早退前）
  │                  └─ 到 _EndTime 时：_ApplyRootMotion + Play
```

---

## 六、代码注释引用约定

后续 `animation_source.lua` 及测试代码的注释中，涉及以下议题时只写简要说明
加本文档章节引用即可，不再重复推演：

| 议题                               | 引用章节 |
| ---------------------------------- | -------- |
| `entPos` 与 `bonePos` 的关系       | §一      |
| 循环处跳跃的机制                   | §二、§三 |
| 陷地 / 悬空的机制                  | §二、§四 |
| `_ApplyRootMotion` 只取水平分量    | §3.4     |
| 垂直通道参考点用骨骼位置           | §4.3     |
| 垂直通道用基线而非差分             | §4.4     |
| 垂直通道为什么不受动画起伏影响     | §4.5     |
| `GROUND_EPSILON` 的存在理由        | §4.6     |
| `SetPos` 必须在 `Spawn` 之前       | §5.1     |
| `_Duration` 与 `_EndTime` 分离     | §5.2     |
| 用 `Fire` 系列而非 `ResetSequence` | §5.3     |
| `timer.Simple(0, ...)` 的必要性    | §5.3     |

引用写法示例：

```lua
-- Pos 必须在 Spawn 之前设置，原因见 docs/animation_source_timing.md §5.1。
if pos then ent:SetPos(pos) end
if ang then ent:SetAngles(ang) end
ent:Spawn()
```
